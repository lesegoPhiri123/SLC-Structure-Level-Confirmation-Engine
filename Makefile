PYTHON ?= python3
MT5_DATA_DIR ?=

.PHONY: help web sample-data deploy-ea clean

help:
	@echo "SLC Engine"
	@echo ""
	@echo "  make web                              run the web visualizer at http://localhost:8081"
	@echo "  make sample-data                      regenerate data/sample_state.json"
	@echo "  make deploy-ea MT5_DATA_DIR=<path>     copy the (single-file) EA into an MT5 data folder"
	@echo "  make clean                             remove generated artifacts"

web: data/sample_state.json
	$(PYTHON) web/server.py

sample-data:
	$(PYTHON) scripts/gen_sample_data.py

data/sample_state.json:
	$(PYTHON) scripts/gen_sample_data.py

deploy-ea:
ifeq ($(strip $(MT5_DATA_DIR)),)
	$(error Usage: make deploy-ea MT5_DATA_DIR="/path/to/MetaTrader 5")
endif
	mkdir -p "$(MT5_DATA_DIR)/MQL5/Experts"
	cp mql5/Experts/SLC_Engine.mq5 "$(MT5_DATA_DIR)/MQL5/Experts/"
	@echo ""
	@echo "Copied. Open MetaEditor, load SLC_Engine.mq5, and compile (F7)."
	@echo "Headless MetaEditor compilation isn't automated here (Windows-only, environment-specific)."

clean:
	rm -f data/sample_state.json
