.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help
	@awk 'BEGIN {FS = ":.*##"; print "usage: make <target>\n"} \
		/^##@/ { printf "\n\033[1m%s:\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Building
.PHONY: build run release install clean
build: ## build a debug app for this Mac into build/debug
	scripts/build.sh debug

run: build ## build and open the debug app
	open build/debug/Insomnia.app

release: ## build the universal release app into build/release
	scripts/build.sh release

install: ## build the release app and install it to /Applications
	scripts/build.sh release --install

clean: ## remove every build output
	rm -rf build .build

##@ Checks
.PHONY: test
test: ## run the unit tests
	swift test

##@ Debugging
.PHONY: log
log: ## follow what Insomnia logs, such as the bag score
	log stream --predicate 'subsystem == "com.michalptacek.insomnia"' --level info
