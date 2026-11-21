#ifndef ALPINE_SOLAR_PROFILE
#define ALPINE_SOLAR_PROFILE
// The first nine t26 texels hold diffuse SH. The rest cover the same
// 10 m to 12 km altitude range as the atmosphere integrator.
static const uint SKY_SH_COUNT = 9;
static const uint SOLAR_PROFILE_INTERVALS = 64;
static const float SOLAR_PROFILE_BASE_M = 10.0;
static const float SOLAR_PROFILE_CEILING_M = 12000.0;
#endif
