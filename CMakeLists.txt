cmake_minimum_required(VERSION 3.20.0)

if(CONFIG_TOTEM_LIGHTHOUSE)
	target_sources(app PRIVATE src/lighthouse.c)
endif()
