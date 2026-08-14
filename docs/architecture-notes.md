# Architecture notes

Rough design notes that don't fit in the README. Mostly decisions I don't want
to re-litigate in a group chat at 2am.

## Why two NAT gateways

Because one NAT is a single point of failure and AWS charges per hour either
way, so we might as well have a spare. Also the network diagram looks cooler.

## Why LVM on a raw EBS volume

The rubric demands LVM, and LVM on a pre-formatted EBS volume is just
formatting with extra steps. Raw device means the playbook owns the whole
stack: pvcreate, vgcreate, lvcreate, mkfs, mount, fstab. Zero ambiguity.

## Why Secrets Manager instead of tfvars

Tfstate is world-readable to anyone with bucket access, and tfvars love to
sneak into git commits. The secret pipeline is: .env on the laptop, terraform
outputs in memory, Secrets Manager at rest, ESO into the pod. No plaintext
passwords anywhere in between. If you find a password in tfstate, something
has gone deeply wrong and you should feel bad.
