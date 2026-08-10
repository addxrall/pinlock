APP  = pinlock.app
BIN  = $(APP)/Contents/MacOS/pinlock
FW   = -framework Cocoa -framework IOKit -framework Collaboration \
       -framework QuartzCore -framework ServiceManagement -framework Carbon

.PHONY: all install uninstall clean

all: $(APP)

$(APP): $(BIN) $(APP)/Contents/Info.plist
	codesign -s - --force $(APP)
	@touch $(APP)

$(BIN): pinlock.m
	@mkdir -p $(@D)
	clang -fobjc-arc -O2 -Wall $(FW) -o $@ pinlock.m

$(APP)/Contents/Info.plist: Info.plist
	@mkdir -p $(@D)
	cp $< $@

install: all
	-pkill -x pinlock
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	open /Applications/$(APP)

uninstall:
	-pkill -x pinlock
	rm -rf /Applications/$(APP)

clean:
	rm -rf $(APP)
