SHELL ?= /bin/bash -e
# Set this before building the ocs-api binary and FDO-owner-services (for now they use the samme version number)
export VERSION ?= 1.8.0
export FIDO_DEVICE_ONBOARD_REL_VER ?= 1.1.10
# used by sample-mfg/Makefile. Needs to match what is in fdo/supply-chain-tools-v<version>/docker_manufacturer/docker-compose.yml
STABLE_VERSION ?= 1.8.0

#todo: add BUILD_NUMBER like in anax/Makefile

export DOCKER_REGISTRY ?= openhorizon
export FDO_DOCKER_IMAGE ?= fdo-owner-services
FDO_IMAGE_LABELS ?= --label "vendor=Open Horizon" --label "name=$(FDO_DOCKER_IMAGE)" --label "version=$(VERSION)" --label "release=$(shell git rev-parse --short HEAD)" --label "summary=Open Horizon FDO support image" --label "description=The FDO owner services run in the context of the open-horizon management hub"
# This doesn't work. According to https://docs.docker.com/engine/reference/builder/#label it is not necessary to put all of the labels in a single image layer
#FDO_IMAGE_LABELS ?= --label 'vendor=IBM name=$(FDO_DOCKER_IMAGE) version=$(VERSION) release=$(shell git rev-parse --short HEAD) summary="Open Horizon FDO support image" description="The FDO owner services run in the context of the open-horizon management hub"'

# can override this in the environment, e.g. set it to: --no-cache
DOCKER_OPTS ?=

# Used to set the version in the ocs-api executable
# if VERSION is like 1.10.1-105.202011140410.c6b4a80 it will strip the last 2 fields and end up with 1.10.1-105
TRIMMED_VERSION := $(shell echo '$(VERSION)' | sed -e 's/\(-[0-9]*\)\..*/\1/')
#GO_BUILD_LDFLAGS ?= -ldflags="-X 'github.com/open-horizon/FDO-support/main.OCS_API_VERSION=$(VERSION)'"
GO_BUILD_LDFLAGS ?= -ldflags="-X 'main.OCS_API_VERSION=$(VERSION)'"

default: $(FDO_DOCKER_IMAGE)

fdo:
	mkdir fdo

fdo/NOTICES-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz: fdo
	wget -P fdo https://github.com/fido-device-onboard/pri-fidoiot/releases/download/v$(FIDO_DEVICE_ONBOARD_REL_VER)/pri-fidoiot-NOTICES-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz

fdo/NOTICES-v$(FIDO_DEVICE_ONBOARD_REL_VER): fdo/NOTICES-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz
	tar -zxf fdo/pri-fidoiot-NOTICES-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz -C fdo

fdo/pri-fidoiot-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz: fdo
	wget -P fdo https://github.com/fido-device-onboard/pri-fidoiot/releases/download/v$(FIDO_DEVICE_ONBOARD_REL_VER)/pri-fidoiot-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz

fdo/pri-fidoiot-v$(FIDO_DEVICE_ONBOARD_REL_VER): fdo/pri-fidoiot-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz
	tar -zxf fdo/pri-fidoiot-v$(FIDO_DEVICE_ONBOARD_REL_VER).tar.gz -C fdo


# Build the ocs rest api for linux for the FDO-owner-services container
ocs-api/linux/ocs-api: ocs-api/*.go ocs-api/*/*.go Makefile
	mkdir -p ocs-api/linux
	(cd ocs-api && GOOS=linux go build $(GO_BUILD_LDFLAGS) -o linux/ocs-api -buildvcs=false)

# For building and running the ocs rest api on mac for debugging
ocs-api/ocs-api: ocs-api/*.go ocs-api/*/*.go Makefile
	(cd ocs-api && go build $(GO_BUILD_LDFLAGS) -o ocs-api)

run-ocs-api: ocs-api/ocs-api
	- tools/stop-ocs-api.sh || :
	tools/start-ocs-api.sh

# Build the FDO services docker image - see the build environment requirements listed in docker/Dockerfile
$(FDO_DOCKER_IMAGE): ocs-api/linux/ocs-api fdo/NOTICES-v$(FIDO_DEVICE_ONBOARD_REL_VER) fdo/pri-fidoiot-v$(FIDO_DEVICE_ONBOARD_REL_VER)
	- docker rm -f $(FDO_DOCKER_IMAGE) 2> /dev/null || :
	docker build --build-arg="fido_device_onboard_rel_ver=$(FIDO_DEVICE_ONBOARD_REL_VER)" -t $(DOCKER_REGISTRY)/$@:$(VERSION) $(FDO_IMAGE_LABELS) $(DOCKER_OPTS) -f docker/Dockerfile .

# Run the FDO services docker container
# If you want to run the image w/o rebuilding: make -W FDO-owner-services -W ocs-api/linux/ocs-api run-FDO-owner-services
run-$(FDO_DOCKER_IMAGE): $(FDO_DOCKER_IMAGE)
	: $${HZN_EXCHANGE_URL:?} $${HZN_FSS_CSSURL:?} $${HZN_MGMT_HUB_CERT:?}
	- docker rm -f $(FDO_DOCKER_IMAGE) 2> /dev/null || :
	docker/run-fdo-owner-service.sh $(VERSION)

# Push the FDO services docker image that you are still working on to the registry. This is necessary if you are testing on a different machine than you are building on.
dev-push-$(FDO_DOCKER_IMAGE):
	docker push $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION)

# Push the FDO services docker image to the registry and tag as testing
push-$(FDO_DOCKER_IMAGE):
	docker push $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION)
	docker tag $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION) $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):testing
	docker push $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):testing

# Push the FDO services docker image to the registry and tag as latest
publish-$(FDO_DOCKER_IMAGE):
	docker push $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION)
	docker tag $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION) $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):latest
	docker push $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):latest
	docker tag $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION) $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(STABLE_VERSION)
	docker push $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(STABLE_VERSION)

# Use this if you are on a machine where you did not build the image
pull-$(FDO_DOCKER_IMAGE):
	docker pull $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):$(VERSION)

clean:
	go clean
	rm -fr fdo ocs-api/ocs-api ocs-api/linux/ocs-api
	- docker rm -f $(FDO_DOCKER_IMAGE) 2> /dev/null || :
	- docker rmi $(DOCKER_REGISTRY)/$(FDO_DOCKER_IMAGE):{$(VERSION),latest,$(STABLE_VERSION)} 2> /dev/null || :

.PHONY: default run-ocs-api run-$(FDO_DOCKER_IMAGE) push-$(FDO_DOCKER_IMAGE) publish-$(FDO_DOCKER_IMAGE) promote-$(FDO_DOCKER_IMAGE) pull-$(FDO_DOCKER_IMAGE) clean