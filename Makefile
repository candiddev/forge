.PHONY: lint
lint:
	docker run --rm -v "$${PWD}:/mnt" koalaman/shellcheck:stable forge.sh
