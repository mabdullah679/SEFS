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
      REPO_URL       = aws_ecr_repository.this[each.key].repository_url
      REPO           = aws_ecr_repository.this[each.key].name
      TAG            = local.content_hash[each.key]
      CONTEXT        = each.value
      PLATFORM       = var.platform
      BUILD_TIMEOUT  = tostring(var.build_timeout_seconds)
      BUILD_ATTEMPTS = tostring(var.build_attempts)
    }
    command = <<-EOT
      set -eu
      # Each build gets a throwaway Docker config holding the ECR credential directly.
      # No `docker login`: the writer and reader builds run in parallel, and concurrent
      # logins collide in the host credential store (macOS keychain error -25299,
      # reproduced 3/3). A fresh config is not enough on its own: with no auths in it,
      # the CLI auto-selects the keychain helper anyway (observed). Writing `auths`
      # directly keeps the CLI on the file store, and the token dies with the temp dir.
      DOCKER_HOST="$${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
      export DOCKER_HOST
      umask 077
      DOCKER_CONFIG="$(mktemp -d)"
      export DOCKER_CONFIG
      trap 'rm -rf "$DOCKER_CONFIG"' EXIT
      if [ -d "$HOME/.docker/cli-plugins" ]; then
        ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins" # keep buildx visible
      fi
      REGISTRY="$${REPO_URL%%/*}"
      REGION="$(printf '%s' "$REGISTRY" | cut -d. -f4)"
      AUTH="$(aws ecr get-login-password --region "$REGION" | sed 's/^/AWS:/' | tr -d '\n' | base64 | tr -d '\n')"
      printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$REGISTRY" "$AUTH" > "$DOCKER_CONFIG/config.json"
      # Tags are IMMUTABLE: if this exact content is already pushed, there is nothing to do.
      if aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
           --image-ids imageTag="$TAG" >/dev/null 2>&1; then
        echo "image $REPO_URL:$TAG already present, skipping build"
        exit 0
      fi
      # A push over a bad link can crawl for hours while the rest of the stack bills
      # (observed 2026-10-25: 2h09m at ~37 KB/s, then "broken pipe"). Bound each attempt
      # with a watchdog and retry; macOS has no `timeout`, hence the shell version.
      attempt=0
      while :; do
        attempt=$((attempt + 1))
        docker buildx build --platform "$PLATFORM" --provenance=false \
          --tag "$REPO_URL:$TAG" --push "$CONTEXT" &
        bpid=$!
        ( sleep "$BUILD_TIMEOUT" && kill "$bpid" 2>/dev/null && echo "watchdog: attempt $attempt exceeded $BUILD_TIMEOUT s, killed" ) &
        wpid=$!
        if wait "$bpid"; then kill "$wpid" 2>/dev/null; break; fi
        kill "$wpid" 2>/dev/null
        if [ "$attempt" -ge "$BUILD_ATTEMPTS" ]; then
          echo "build/push of $REPO_URL:$TAG failed after $attempt attempts" >&2
          exit 1
        fi
        echo "attempt $attempt failed; retrying in 15 s"; sleep 15
      done
    EOT
  }
}
