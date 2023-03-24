MAIN = iib-explorer.sh
TARGET = $(CURDIR)/target

build:
	@echo "Create $(TARGET)"
	@mkdir -p $(TARGET)
	@echo "source $(CURDIR)/$(MAIN)" > $(TARGET)/main.sh
	@bash --verbose $(TARGET)/main.sh > $(TARGET)/build.sh 2>&1 || true
	@sed -i 's/BASH_SOURCE\[0\]/0/g' $(TARGET)/build.sh
	@sed -i '/^source/d' $(TARGET)/build.sh
	@cd $(TARGET) && shc -f build.sh -o iib-explorer
