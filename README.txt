SEFS - SHARED EFS FOR A PYTHON WRITER AND A SPRING BOOT READER (plain twin of README.md, 2026-10-25)

WHAT IT IS
One command builds, in your own AWS account: a private network across two data centres, one encrypted shared file system, a Python app that writes files to it and a Spring Boot app that reads the same files but cannot write, daily backups kept 35 days, a rule that moves untouched files to cheaper storage after 30 days, alarms and a dashboard, a read-only checking role, and the plumbing that lets every later change deploy itself when you push to GitHub with the word "check".
It implements the spec "Shared EFS for Multi-App.docx". The 15 requirements are numbered R1 to R15 in PLAN.md. If an AI agent is helping you, point it at AGENTS.md first.

WHAT YOU NEED
An AWS account you can administer and a login for it. An empty GitHub repository you own, because the automation's deploy role trusts exactly one repository and its main branch. On your machine: Terraform 1.9 or newer, Docker, the AWS command line (version 2), jq, make and bash (Windows: use WSL2). You don't need Java, Maven or Python; the apps build inside Docker. Your upload link should manage about 250 KB/s or better for a first deploy from a laptop (about 290 MB of images); deploys from GitHub don't have that problem.

HOW TO RUN
Run this single command and enter inputs where requested: ./sefs setup (after signing in to AWS in your shell). ./sefs help lists every other verb; ./sefs show <keyword> prints any deployed ID (efs, subnet, cluster, log, backup...), ./sefs status shows services, file system and alarms, ./sefs logs writer or reader shows the newest app log. The numbered steps say the same thing in full.
1. Create an empty repository on GitHub, clone this one, point it at yours, and push.
2. Sign in to AWS in your shell.
3. Run ./sefs setup (the same as ./setup.sh). It checks your tools, shows which AWS account you're signed in to and asks you to confirm, asks for the region, an alarm e-mail (optional) and your GitHub repository, writes a local settings file that never leaves your machine, creates the shared state storage and the deploy role once, asks for any secrets the project lists (none today) and stores them only in AWS's parameter store, then deploys everything (about 8 minutes).
4. setup prints five values for GitHub and, if you are signed in to the GitHub command line, offers to set them for you. Otherwise add them yourself in your repository's Actions variables: the region, the account ID, the deploy role, the state bucket and the lock table. No secrets are needed.
5. From then on, push to main with the word "check" on its own in the commit message ("checks" does not count): only the pieces that changed are redeployed and every requirement is re-checked against live AWS. "check full" redeploys everything. A deploy waits for a human approval in GitHub if you keep the "production" environment's required reviewer switched on.

Other commands: make verify (check every requirement against live AWS), make e2e (prove the behaviour, including that the reader can't write even with its read-only flag off), make bruno (the Bruno collection), and CONFIRM_DESTROY_DATA=yes make down (delete everything, including the data; the state storage stays unless you add DESTROY_STATE=yes).

IF SOMETHING REFUSES TO RUN
- "credentials are account X, allowed is Y": you're signed in to the wrong account. The allowed account lives in the local settings file.
- "is an aws login session": Terraform's state storage can't read that login type. make tf-profile creates a helper profile that passes the same login through; setup.sh does this for you.
- "backend.hcl missing": run make bootstrap.
- A failed or cancelled deploy: push again with "check full"; a small adopt step re-attaches anything AWS kept.
- Region: any region with at least two data centres; only Sydney (ap-southeast-2) has been exercised live.

WHAT IT DOES
A private network in two or more data centres; both apps in private subnets with no public addresses; one file-system mount point per data centre, reachable only from the apps on port 2049; the writer writes files as user 1001 and the reader reads the same files as user 1002 and is refused when it tries to write; the file system is encrypted, uses standard performance, and moves old files to cheaper storage after 30 days; backups run daily and are kept 35 days; if the apps are destroyed the data survives and the apps re-attach on the next deploy; ten alarms (apps down, storage credits or connections, network port errors, backup failures, app errors, and a security alarm if the reader ever manages to write) go to an e-mail topic, and a dashboard shows the lot.

THE ONE PLACE WE DIFFER FROM THE SPEC
The spec suggests an EFS access point can make the reader read-only. It can't; access points only set the user, group and folder. The container's read-only flag is easy to remove and the shared folder is writable by the group on purpose. So the real protection is AWS permissions: the reader's role can only mount, and the file system's own policy blocks it from writing. make e2e proves it by running the reader with the read-only flag off and checking that the write still fails.

TESTS AND WHAT HAS BEEN PROVEN
Local tests need no AWS account: fake-AWS tests 45 of 45 plus 4 of 4; 48 deliberate breaks all caught; the Docker writer/reader test 16 of 16; the setup self-test 5 of 5; the CI change mapper 9 of 9; the live checker's own self-test 29 scenarios.
Real AWS, Sydney, 2026-10-25: one command deployed 55 resources in about 8 minutes; the live checker passed 15 of 15 with zero drift; the writer wrote 40 files and the reader read all 40 back identical; the reader was refused even with its read-only flag off; 46 files survived destroying and rebuilding the apps; teardown left the account clean, checked independently.
GitHub Actions, 2026-10-25: a "check" push borrowed the deploy role, used the shared state, deployed everything, confirmed zero drift and passed all 16 live checks, with the deploy job taking under two minutes.
The one command, 2026-10-26, on a stack GitHub had just deployed: ./sefs ran preflight, a clean plan, all 16 live checks, the four behaviour proofs (89 files written and read back identical, the reader refused with the read-only flag off, 92 files survived destroying and rebuilding the apps), the Bruno collection, the cost report, a deploy that correctly changed nothing, a second clean plan, and the teardown. Every read command (show, status, alarms, logs, url) answered from the live stack.
Bruno, 2026-10-26, against that same stack: all 20 requests and 58 of 58 checks passed using only the read-only checking role; feeding it made-up security group IDs makes the network checks fail, which proves they're really looking.

WHAT IT COSTS TO KEEP RUNNING
make cost asks AWS for today's prices in your region. Sydney, 2026-10-26: about 17 cents an hour, a third of a cent a minute, about 125 dollars for 30 days. Three quarters of that is the two NAT gateways (one per data centre); a setting halves that. Published rates, not an invoice; the 30-day number is the hourly rate times 720 hours, because the stack has not run long enough for a real monthly bill.
Not proven: the single command run start to finish on a clean laptop by someone other than the author (each step is tested and proven live, the whole path on a fresh machine is for you to confirm); which exact error a blocked write returns (we saw "read-only file system"); a backup job finishing (the 35-day backup is proven as configuration only); a control run of the same read-only test using the writer's role.

WHERE THINGS ARE
main.tf is the mother that wires everything; modules/ holds the children (network, security, efs, backup, images, apps, observability, access, registry, bootstrap); apps/ holds the two programs; setup.sh, Makefile and scripts/ hold the automation; .github/workflows/check.yml is the CI; bruno/sefs is the Bruno collection; tests/ holds every suite; docs/ holds the CI guide, the component map, the module contracts, the decisions log and the requirement-to-test map; PLAN.md holds the requirements, the plan and what ships next (the 2.5D GUI). Every .md has a plain-text twin like this one.

DESIGN CHOICES THAT AREN'T OBVIOUS
- One Terraform state for everything, not one per layer: "one command deploys all" would otherwise become several commands. The file system is protected by its delete lock instead, and any piece can still be updated alone, with a clean-plan check afterwards.
- The app images are built during the deploy, and the Java build runs on the builder's own chip type because Java bytecode is portable; building first would need two deploys, and emulating a Java build on GitHub's machines took over 40 minutes.
- The apps wait until the file system's policy exists; without a policy, anyone who can reach the file system can write.
- The app roles get generated names, because a role recreated under the same name would be silently locked out of the file system.
- You create the deploy role, not the automation, and the role can never change itself, so a workflow can't widen its own permissions or delete the state it runs on.
- Secrets never pass through Terraform: setup.sh streams them straight into AWS's parameter store, proven by a test with a fake AWS.
- Everything is pinned: Terraform and provider versions, GitHub actions by commit, base images by exact version, and image tags are content hashes, so the same code always builds the same thing.
