################################################################################
#
# tc-launcher — консольный UI тонкого клиента (см. src/tc-launcher.c)
#
################################################################################

TC_LAUNCHER_VERSION = 1.0
TC_LAUNCHER_SITE = $(BR2_EXTERNAL_THINCLIENT_PATH)/package/tc-launcher/src
TC_LAUNCHER_SITE_METHOD = local
TC_LAUNCHER_DEPENDENCIES = ncurses
TC_LAUNCHER_LICENSE = GPL-2.0+
# LICENSE_FILES не задаём: файл LICENSE лежит в корне BR2_EXTERNAL, а не в
# SITE (src/); для legal-info достаточно SPDX в исходнике и LICENSE репо

define TC_LAUNCHER_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(@D)/tc-launcher $(@D)/tc-launcher.c -lncursesw
endef

define TC_LAUNCHER_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tc-launcher \
		$(TARGET_DIR)/usr/bin/tc-launcher
endef

$(eval $(generic-package))
