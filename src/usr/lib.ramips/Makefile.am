#
# src/usr/lib.ramips/Makefile.am
# This file is part of slide-switch.
#
# Copyright (C) 2016 Jeffery To
# https://github.com/jefferyto/openwrt-slide-switch
#
# slide-switch is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# slide-switch is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with slide-switch.  If not, see <http://www.gnu.org/licenses/>.
#

platformexecdir = $(pkglibdir)
platformexec_DATA = platform.sh ramips.json
TESTS = check-shell-syntax check-json-syntax

include $(top_srcdir)/rules.mk

EXTRA_DIST += $(platformexec_DATA:=-cut)
CLEANFILES += $(platformexec_DATA)
