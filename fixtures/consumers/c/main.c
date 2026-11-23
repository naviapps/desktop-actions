#include <CDesktopActions/desktop_actions.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define PLACEMENT_JSON                                                                             \
    "{\"placement\":{\"kind\":\"fill\"},\"screen\":{\"kind\":\"main\"},\"area\":\"visible\","      \
    "\"inset\":12.5}"
#define ACTION_JSON "{\"kind\":\"action.window.placement\",\"input\":" PLACEMENT_JSON "}"

enum { RESPONSE_CAPACITY = 1024, V1_ENVELOPE = 1, MACOS = 0 };

static void copy_success(DesktopActionsJson *owner, char *response) {
    assert(owner != NULL);
    const DesktopActionsJsonView view = desktop_actions_json_view(owner);
    assert(view.code == 0 && view.has_version == 0);
    assert(view.data != NULL && view.length > 0 && view.length < RESPONSE_CAPACITY);
    memcpy(response, view.data, view.length);
    response[view.length] = '\0';
    desktop_actions_json_destroy(owner);
}

int main(void) {
    _Static_assert(DESKTOP_ACTIONS_ABI_VERSION == 6U, "The installed header must declare ABI 6");
    assert(desktop_actions_abi_version() == DESKTOP_ACTIONS_ABI_VERSION);

    char response[RESPONSE_CAPACITY];
    const char input[] =
        "{ \"action\": { \"input\": { \"inset\": 12.5, \"area\": \"visible\","
        " \"screen\": { \"kind\": \"main\" }, \"placement\": { \"kind\": \"fill\" } },"
        " \"kind\": \"action.window.placement\" }, \"version\": 1 }";
    const char canonical[] = "{\"version\":1,\"action\":" ACTION_JSON "}";
    copy_success(
        desktop_actions_action_normalize((const uint8_t *)input, sizeof input - 1, V1_ENVELOPE),
        response);
    assert(strcmp(response, canonical) == 0);
    copy_success(
        desktop_actions_action_normalize((const uint8_t *)response, strlen(response), V1_ENVELOPE),
        response);
    assert(strcmp(response, canonical) == 0);

    const char unsupported[] = "{\"version\":2,\"action\":" ACTION_JSON "}";
    DesktopActionsJson *error = desktop_actions_action_normalize(
        (const uint8_t *)unsupported, sizeof unsupported - 1, V1_ENVELOPE);
    assert(error != NULL);
    const DesktopActionsJsonView diagnostic = desktop_actions_json_view(error);
    assert(diagnostic.code == 2 && diagnostic.has_version != 0 && diagnostic.version == 2);
    desktop_actions_json_destroy(error);

    const char bare[] = ACTION_JSON;
    copy_success(desktop_actions_action_plan((const uint8_t *)bare, sizeof bare - 1, MACOS),
                 response);
    assert(strstr(response, "\"platform\":\"macos\"") != NULL);
    assert(
        strstr(response,
               "\"steps\":[{\"method\":{\"kind\":\"window-placement\",\"request\":" PLACEMENT_JSON
               "},\"isFallback\":false}]") != NULL);
    assert(strstr(response, "\"isExecutable\":true") != NULL);
    assert(strstr(response, "\"permissions\":{\"primary\":[\"accessibility\"],\"fallback\":[]}") !=
           NULL);
    assert(strstr(response, "\"hints\":[{\"permission\":\"accessibility\","
                            "\"reason\":\"accessibility-windowing\"}]") != NULL);

    puts("Standalone installed C DesktopActions consumer passed v1 normalization and window "
         "planning.");
    return 0;
}
