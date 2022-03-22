all: mutating-admission-webhooks

GO_FLAGS ?= CGO_ENABLED=0 GO111MODULE=on

mutating-admission-webhooks:
	$(GO_FLAGS) go build -mod=vendor -a -o bin/mutating-admission-webhooks .

charts:
	@echo "charts ready"

.PHONY: build-image push-image build-chart push-chart
build-image:
	./hack/build.sh build-image $(WHAT) $(ARCH)

push-image:
	./hack/build.sh push-image $(WHAT) $(ARCH)

build-chart: charts
	./hack/build.sh build-chart $(WHAT)

push-chart:
	./hack/build.sh push-chart $(WHAT)
