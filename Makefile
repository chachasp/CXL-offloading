.PHONY: preflight probe render test

CXL_NODE ?=
IMAGE ?=
CACHE_GB ?= 64
TP ?= 1
NAMESPACE ?= default

preflight:
	./scripts/preflight.sh $(if $(CXL_NODE),--node $(CXL_NODE),)

probe:
	test -n "$(CXL_NODE)"
	python3 scripts/cxl_cuda_probe.py --node "$(CXL_NODE)" --size-mib 64

render:
	test -n "$(IMAGE)"
	test -n "$(CXL_NODE)"
	./scripts/render-manifest.sh --image "$(IMAGE)" --node "$(CXL_NODE)" \
	  --cache-gb "$(CACHE_GB)" --tp "$(TP)" --output rendered/dgd-cxl-tp$(TP).yaml

test:
	python3 -m unittest discover -s tests -v
