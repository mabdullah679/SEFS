SEFS - SHARED EFS FOR A PYTHON WRITER AND A SPRING BOOT READER (plain twin of README.md, 2026-10-25)

WHAT IT IS
One command builds, in a real AWS account: a private network across 2 data centers (AZs), one encrypted shared file system (EFS), a Python app that writes files to it and a Spring Boot app that reads the same files, daily backups kept 35 days, and a rule that moves files nobody has touched for 30 days to cheaper storage.
It implements the spec "Shared EFS for Multi-App.docx". The 15 requirements are numbered R1 to R15 in PLAN.md.

WHAT YOU NEED
Terraform 1.9 or newer, Docker, the AWS CLI logged into the account, make and bash (on Windows, use WSL2). You don't need Java, Maven or Python; the apps are built inside Docker. Nothing listens on your machine.

HOW TO RUN
make up: checks your tools and which AWS account you're in, then deploys everything in one Terraform apply. The app images are built and uploaded as part of that same apply.
make verify: checks every requirement against what AWS actually reports, then confirms Terraform sees no difference between the code and what's running.
make e2e (needs E2E_CONFIRM=yes): proves the writer writes, the reader reads, the reader can't write even with its read-only flag off, and the data survives the apps being destroyed.
CONFIRM_DESTROY_DATA=yes make down: deletes everything including the data, then checks nothing is left.
To update one piece only: make apply-one CHILD=network, security, efs, backup, images or apps. docs/COMPONENTS.md says which piece owns what.

WHY "make down" IS SPECIAL
The file system is protected from deletion, and Terraform deliberately won't let a setting turn that off. So teardown removes the file system from Terraform's tracking, deletes everything else, deletes the file system directly, then looks for anything still tagged with this project.

THE ONE PLACE WE DIFFER FROM THE SPEC
The spec suggests an EFS access point can make the reader read-only. It can't, because access points only set the user, group and folder. The container's read-only flag is easy to remove, and the shared folder is writable by the group on purpose. So the real protection is AWS permissions: the reader's role can only mount, and the file system's own policy explicitly blocks the reader from writing. The e2e test proves it by running the reader with the read-only flag switched off and checking that the write still fails.

TEST RESULTS SO FAR (on the main branch, 2026-10-25)
- Fake-AWS tests: 23 of 23 plus 4 of 4 pass, plus a check that the delete protection is in place. They block all network access, so a passing run made no AWS calls.
- Deliberate-break tests: we broke 28 rules one at a time (for example turning encryption off, opening the firewall, letting the reader write) and all 28 were caught. A harmless change was correctly not flagged, which shows the harness can't fake a catch.
- Docker test: 16 of 16 checks pass. The writer and reader share one folder as their real users, every file the reader read matches what the writer wrote, and the reader's write was blocked. With the reader switched to read-write, the test fails as it should.
- Real AWS: not run yet. It waits on your AWS account.

WHERE THINGS ARE
main.tf is the mother that wires everything. modules/ holds the six pieces (network, security, efs, backup, images, apps). apps/ holds the two programs. tests/ holds the four test kinds. scripts/teardown.sh is the full delete. docs/ holds the decisions log, the component map, the contracts and the requirement-to-test map.

DESIGN CHOICES THAT AREN'T OBVIOUS
- One Terraform state for everything, not one per layer. Separate states would make "one command deploys all" into several commands. The file system is protected by its delete lock instead, and any piece can still be updated alone.
- The images are built during the apply. Pushing them first would need the image registry to exist first, which means two applies.
- The apps wait until the file system's policy exists. Without a policy, EFS lets anyone who can reach it write, and a reader that connected early would keep write access.
- The app roles get generated names. The file system policy is tied to each role's internal AWS ID. A role recreated under the same name would be silently locked out, because Terraform would see nothing to change.
