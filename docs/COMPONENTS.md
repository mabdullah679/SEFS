# Components → child Terraform

The mother ([../main.tf](../main.tf)) deploys every child in one apply: `make up`.
To update **one** component, apply only its child: `make apply-one CHILD=<child>` (= `terraform apply -target=module.<child>`). Terraform also applies whatever that child depends on, if it has changed.

| Component | Child (`CHILD=`) | Code | Note |
|---|---|---|---|
| VPC, subnets, IGW, NAT, routes | `network` | [modules/network](../modules/network) | Changing `az_count` adds/removes mount targets too (efs depends on it) |
| sg-apps, sg-efs, port-2049 rule | `security` | [modules/security](../modules/security) | |
| EFS file system, mount targets, access points, FS policy, IA lifecycle | `efs` | [modules/efs](../modules/efs) | `prevent_destroy`: any change that would *replace* the file system fails on purpose |
| AWS Backup vault, plan, selection, role | `backup` | [modules/backup](../modules/backup) | |
| ECR repos + image build/push | `images` | [modules/images](../modules/images) | Rebuilds only when files in `apps/*` change |
| ECS cluster, task defs, roles, services, logs | `apps` | [modules/apps](../modules/apps) | Safe to destroy/recreate; data stays on EFS |
| Alarms, SNS alerts topic, dashboard, log metric filters, cost allocation tag (opt-in) | `observability` | [modules/observability](../modules/observability) | `alert_email` subscribes an address (confirm the SNS email once) |
| Bruno read-only role | `access` | [modules/access](../modules/access) | |
| Deployed IDs in SSM `/sefs/outputs/*` | `registry` | [modules/registry](../modules/registry) | Non-secret only |
| The 2.5D map: Cognito login, CloudFront + S3 page, read-only Lambda API behind an HTTP API | `gui` | [modules/gui](../modules/gui) | Optional (`enable_gui`, default on). Page sources in `modules/gui/web`, API in `modules/gui/api`; the page is compiled inside the apply by `modules/gui/build.sh` (Docker). Idle cost ≈ 0 |

## Mother vs. granular
- **Whole deployment / larger scale:** use the mother. One state, one apply, one plan that shows every change across children.
- **Granular:** `-target` one child at a time, in the order above. Terraform documents `-target` for exceptional use, so run a full `make plan` afterwards to confirm the mother sees no leftover drift.
- Destroying only the apps: `terraform destroy -target=module.apps`. This also removes the EFS file-system policy (it references the task roles), and the next apply re-creates it before the services start.
