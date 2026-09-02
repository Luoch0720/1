# TelegramVoiceNoteTweak — Theos Makefile
# 编译环境：WSL2 Ubuntu + Theos + iPhoneOS SDK
# 编译：make package THEOS_PACKAGE_SCHEME=rootless

TARGET := iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = Telegram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TelegramVoiceNoteTweak

TelegramVoiceNoteTweak_FILES = Tweak.xm FakeVoiceManager.m
TelegramVoiceNoteTweak_CFLAGS = -fobjc-arc -I. -Wno-deprecated-declarations -Wno-error -fno-modules
TelegramVoiceNoteTweak_FRAMEWORKS = UIKit Foundation AVFoundation UniformTypeIdentifiers

include $(THEOS_MAKE_PATH)/tweak.mk
