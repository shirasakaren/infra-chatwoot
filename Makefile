# Makefile, because sometimes you don't want to remember every flag.
# honestly this is 90% muscle memory shortcuts. do NOT @ me about make being old.
# (verify target added because i kept forgetting ./scripts/verify.sh existed)

.PHONY: help fmt plan apply destroy verify

help:
	@echo "targets: fmt plan apply destroy verify"

fmt:
	terraform -chdir=terraform fmt -recursive

plan:
	terraform -chdir=terraform plan -input=false

apply:
	terraform -chdir=terraform apply -input=false -auto-approve

destroy:
	./destroy.sh

verify:
	./scripts/verify.sh
