// original imgui.h contains all sorts of c++ stuff, translateC will always fail.
// this just need to contain enough typedefs for the dx* header to zig translation.
#pragma once

#include <float.h> 
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <stdbool.h>

#ifndef IMGUI_API
#define IMGUI_API
#endif
#ifndef IMGUI_IMPL_API
#define IMGUI_IMPL_API              IMGUI_API
#endif

typedef struct ImDrawData ImDrawData;
typedef struct ImTextureData ImTextureData;