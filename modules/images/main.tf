# images: ECR repos + build/push INSIDE the apply (docs/CONTRACTS.md section 3 "images").
# Host needs Docker (with buildx) and the AWS CLI only; Java/Maven/Python live in the
# multi-stage Dockerfiles.

locals {
  contexts = {
    writer = var.writer_context
    reader = var.reader_context
  }

  # Build outputs and caches never change the image (.dockerignore keeps them out of
  # the context too), so they must not change the hash either.
  hash_excludes = "^(target/|\\.idea/|.*__pycache__/|.*\\.pyc$|.*\\.iml$|.*\\.DS_Store$)"

  context_files = {
    for k, ctx in local.contexts : k => sort([
      for f in fileset(ctx, "**") : f if length(regexall(local.hash_excludes, f)) == 0
    ])
  }

  # Content hash per image: sha1 over "<relative path>:<sha1 of file>" for every file
  # in the build context. This is the image tag and the rebuild trigger.
  content_hash = {
    for k, ctx in local.contexts : k => sha1(join("\n", [
      for f in local.context_files[k] : "${f}:${filesha1("${ctx}/${f}")}"
    ]))
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.contexts

  name                 = "${var.name}-${each.key}"
  force_delete         = true
  image_tag_mutability = "IMMUTABLE" # tag = content hash, so a tag never legitimately moves

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "terraform_data" "build" {
  for_each = local.contexts

  # Any change to the context content, the target repo, or the platform rebuilds + pushes.
  triggers_replace = {
    content_hash = local.content_hash[each.key]
    repository   = aws_ecr_repository.this[each.key].repository_url
    platform     = var.platform
  }

  # `output` mirrors this, and is unknown until this resource (i.e. the push) completes.
  input = local.content_hash[each.key]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      REPO_URL = aws_ecr_repository.this[each.key].repository_url
      REPO     = aws_ecr_repository.this[each.key].name
      TAG      = local.content_hash[each.key]
      CONTEXT  = each.value
      PLATFORM = var.platform
    }
    command = <<-EOT
      set -eu
      REGISTRY="$${REPO_URL%%/*}"
      REGION="$(printf '%s' "$REGISTRY" | cut -d. -f4)"
      aws ecr get-login-password --region "$REGION" \
        | docker login --username AWS --password-stdin "$REGISTRY"
      # Tags are IMMUTABLE: if this exact content is already pushed, there is nothing to do.
      if aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
           --image-ids imageTag="$TAG" >/dev/null 2>&1; then
        echo "image $REPO_URL:$TAG already present, skipping build"
        exit 0
      fi
      docker buildx build --platform "$PLATFORM" --provenance=false \
        --tag "$REPO_URL:$TAG" --push "$CONTEXT"
    EOT
  }
}
