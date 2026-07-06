# Makefile, because sometimes you don't want to remember every flag.
# honestly this is 90% muscle memory shortcuts. do NOT @ me about make being old.

.PHONY: help fmt plan apply destroy

help:
	@echo "targets: fmt plan apply destroy"

fmt:
	terraform -chdir=terraform fmt -recursive

plan:
	terraform -chdir=terraform plan -input=false

apply:
	terraform -chdir=terraform apply -input=false -auto-approve

destroy:
	./destroy.sh
