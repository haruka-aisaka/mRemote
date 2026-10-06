/* The C ABI over FreeRDP, plus the app's own PCM ring (App/Audio). Nothing
 * above App/RDP/ may use the bridge types: the whole
 * point of the bridge is that no FreeRDP type reaches a feature module. */
#import "../../bridge/include/mremote/rdp_bridge.h"
#include "../Audio/mr_pcm_ring.h"
