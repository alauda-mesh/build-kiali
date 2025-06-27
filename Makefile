SHELL=/bin/bash

ROOTDIR=$(CURDIR)
OUTDIR=${ROOTDIR}/_output

OPERATOR_SDK_VERSION ?= 1.40.0

HUB ?= build-harbor.alauda.cn/asm

KIALI_OPERATOR_BUNDLE_VERSION ?= 2.11.0

KIALI_OPERATOR_VERSION ?= 2.11.0
KIALI_OPERATOR_REGISTRY ?= $(HUB)/kiali-operator:$(KIALI_OPERATOR_VERSION)
KIALI_DEFAULT_SUPPORTED_IMAGES ?= kiali-operator/playbooks/kiali-default-supported-images.yml

KIALI_2_11_VERSION ?= v2.11.0
KIALI_2_11 ?= $(HUB)/kiali:$(KIALI_2_11_VERSION)
CREATED_AT ?= 2025-06-27T00:00:00Z

PLATFORM := $(shell uname -s | tr '[:upper:]' '[:lower:]')
MACHINE_TYPE := $(shell uname -m)

ifneq (,$(filter x86_64,$(MACHINE_TYPE)))
ARCH := amd64
else ifneq (,$(filter i686,$(MACHINE_TYPE)))
ARCH := 386
else ifneq (,$(filter arm64% aarch64%,$(MACHINE_TYPE)))
ARCH := arm64
else ifneq (,$(filter arm%,$(MACHINE_TYPE)))
ARCH := arm
else
ARCH := amd64
$(warning Unable to detect CPU arch from machine type $(MACHINE_TYPE), assuming $(ARCH))
endif

.PHONY: .download-operator-sdk-if-needed
.download-operator-sdk-if-needed:
	@if [ "$(shell which operator-sdk 2>/dev/null || echo -n "")" == "" ]; then \
		mkdir -p "$(OUTDIR)/operator-sdk-install" ;\
		if [ -x "$(OUTDIR)/operator-sdk-install/operator-sdk" ]; then \
		echo "You do not have operator-sdk installed in your PATH. Will use the one found here: $(OUTDIR)/operator-sdk-install/operator-sdk" ;\
		else \
		echo "You do not have operator-sdk installed in your PATH. The binary will be downloaded to $(OUTDIR)/operator-sdk-install/operator-sdk" ;\
		echo https://github.com/operator-framework/operator-sdk/releases/download/v${OPERATOR_SDK_VERSION}/operator-sdk_$(PLATFORM)_$(ARCH) ;\
		curl -sSL https://github.com/operator-framework/operator-sdk/releases/download/v${OPERATOR_SDK_VERSION}/operator-sdk_$(PLATFORM)_$(ARCH) > "$(OUTDIR)/operator-sdk-install/operator-sdk" ;\
		chmod +x "$(OUTDIR)/operator-sdk-install/operator-sdk" ;\
		fi ;\
	fi

.PHONY: .ensure-operator-sdk-exists
.ensure-operator-sdk-exists: .download-operator-sdk-if-needed
	@$(eval OP_SDK ?= $(shell which operator-sdk 2>/dev/null || echo "$(OUTDIR)/operator-sdk-install/operator-sdk"))
	@$(OP_SDK) version

.PHONY: bundle-manifests
bundle-manifests: .ensure-operator-sdk-exists
	mkdir -p $(OUTDIR) && \
		rm -rf $(OUTDIR)/kiali-operator-bundle && \
		cp -R kiali-operator-bundle $(OUTDIR) && \
		KIALI_OPERATOR_BUNDLE_VERSION=$(KIALI_OPERATOR_BUNDLE_VERSION) \
		KIALI_OPERATOR_VERSION=$(KIALI_OPERATOR_VERSION) \
		KIALI_OPERATOR_REGISTRY=$(KIALI_OPERATOR_REGISTRY) \
		CREATED_AT=$(CREATED_AT) \
		KIALI_2_11=$(KIALI_2_11) \
		envsubst < kiali-operator-bundle/manifests/kiali.clusterserviceversion.yaml | tee $(OUTDIR)/kiali-operator-bundle/manifests/kiali.clusterserviceversion.yaml
	$(OP_SDK) bundle validate $(OUTDIR)/kiali-operator-bundle
