#ifdef NDEBUG
#undef NDEBUG
#endif
#include "desktop_actions.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void canonical_json(void) {
    const char *request =
        "{\"kind\":\"action.workspace.open-url\",\"input\":\"  https://example.com  \"}";
    for (unsigned i = 0; i < 1000; ++i) {
        DesktopActionsJson *owner =
            desktop_actions_action_normalize((const uint8_t *)request, strlen(request), 0);
        DesktopActionsJsonView view = desktop_actions_json_view(owner);
        assert(view.code == 0 && view.data != NULL && view.length > 0);
        uint8_t *copy = malloc(view.length);
        assert(copy);
        memcpy(copy, view.data, view.length);
        size_t length = view.length;
        desktop_actions_json_destroy(owner);
        // Only the owned copy remains valid after the native owner is destroyed.
        DesktopActionsJson *second = desktop_actions_action_normalize(copy, length, 0);
        assert(desktop_actions_json_view(second).code == 0);
        desktop_actions_json_destroy(second);
        free(copy);
    }
    DesktopActionsJson *bad = desktop_actions_action_normalize(NULL, 0, 0);
    assert(desktop_actions_json_view(bad).code == 1);
    desktop_actions_json_destroy(bad);
    bad = desktop_actions_action_normalize((const uint8_t *)request, strlen(request), 99);
    assert(desktop_actions_json_view(bad).code == 1);
    desktop_actions_json_destroy(bad);
    const char *future = "{\"version\":999}";
    bad = desktop_actions_action_normalize((const uint8_t *)future, strlen(future), 1);
    DesktopActionsJsonView v = desktop_actions_json_view(bad);
    assert(v.code == 2 && v.has_version == 1 && v.version == 999);
    desktop_actions_json_destroy(bad);
    assert(desktop_actions_json_view(NULL).code != 0);
    desktop_actions_json_destroy(NULL);
}

static void text_input(void) {
    const char *request = "{\"identifier\":\"action.workspace.run-shortcut\",\"value\":\"MORNING\","
                          "\"platform\":\"macos\",\"shortcuts\":[\"Morning\",\"morning\"]}";
    DesktopActionsJson *owner =
        desktop_actions_text_input_evaluate((const uint8_t *)request, strlen(request));
    DesktopActionsJsonView view = desktop_actions_json_view(owner);
    assert(view.code == 0 && view.data && view.length > 0);
    char *copy = malloc(view.length + 1);
    assert(copy);
    memcpy(copy, view.data, view.length);
    copy[view.length] = 0;
    desktop_actions_json_destroy(owner);
    assert(strstr(copy, "ambiguous-shortcut") && strstr(copy, "\"canConfirm\":false"));
    free(copy);
    owner = desktop_actions_text_input_evaluate(NULL, 0);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    const char *invalid =
        "{\"identifier\":\"action.editing.copy\",\"value\":\"draft\",\"platform\":\"macos\"}";
    owner = desktop_actions_text_input_evaluate((const uint8_t *)invalid, strlen(invalid));
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
}

static void input_metadata(void) {
    const char *parameter =
        "{\"name\":\" url \",\"description\":\" URL \",\"exampleInput\":{\"shape\":\"string\","
        "\"value\":\" example \"}}";
    const char *expected =
        "{\"name\":\"url\",\"description\":\"URL\",\"exampleInput\":{\"shape\":\"string\","
        "\"value\":\"example\"}}";
    DesktopActionsJson *owner =
        desktop_actions_input_metadata_normalize((const uint8_t *)parameter, strlen(parameter), 0);
    DesktopActionsJsonView view = desktop_actions_json_view(owner);
    assert(view.code == 0 && view.data && view.length == strlen(expected));
    assert(memcmp(view.data, expected, view.length) == 0);
    desktop_actions_json_destroy(owner);
    owner =
        desktop_actions_input_metadata_normalize((const uint8_t *)parameter, strlen(parameter), 9);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
}

static void planning(void) {
    const char *request = "{\"kind\":\"action.editing.copy\"}";
    DesktopActionsJson *owner =
        desktop_actions_action_plan((const uint8_t *)request, strlen(request), 0);
    DesktopActionsJsonView view = desktop_actions_json_view(owner);
    assert(view.code == 0 && view.data && view.length > 0);
    char *copy = malloc(view.length + 1);
    assert(copy);
    memcpy(copy, view.data, view.length);
    copy[view.length] = 0;
    desktop_actions_json_destroy(owner);
    assert(strstr(copy, "\"keyCode\":8") && strstr(copy, "accessibility-key-event"));
    free(copy);
    const char *bad = "[{\"method\":{\"kind\":\"hide-frontmost-application\",\"extra\":1}}]";
    owner = desktop_actions_plan_metadata((const uint8_t *)bad, strlen(bad), 0);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_action_plan((const uint8_t *)request, strlen(request), 99);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    const char *identifier = "action.window.placement";
    owner = desktop_actions_action_kind_plan((const uint8_t *)identifier, strlen(identifier), 0);
    view = desktop_actions_json_view(owner);
    assert(view.code == 0 && view.data && view.length > 0);
    copy = malloc(view.length + 1);
    assert(copy);
    memcpy(copy, view.data, view.length);
    copy[view.length] = 0;
    desktop_actions_json_destroy(owner);
    assert(strstr(copy, "\"isExecutable\":true") && strstr(copy, "accessibility-windowing"));
    free(copy);
    const uint8_t invalid_utf8[] = {0xff};
    owner = desktop_actions_action_kind_plan(invalid_utf8, sizeof invalid_utf8, 0);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
}

static void macos_editing_chord(void) {
    const char redo[] = "action.editing.redo";
    DesktopActionsMacosEditingChord chord =
        desktop_actions_macos_editing_chord((const uint8_t *)redo, sizeof(redo) - 1);
    assert(chord.letter == 'z' && chord.key_code == 6 && chord.modifiers == 3);
    chord = desktop_actions_macos_editing_chord((const uint8_t *)redo, 1);
    assert(chord.letter == 0 && chord.key_code == 0 && chord.modifiers == 0);
    chord = desktop_actions_macos_editing_chord(NULL, 1);
    assert(chord.letter == 0 && chord.key_code == 0 && chord.modifiers == 0);
}

static void action_run_ownership(void) {
    const char *request = "{\"kind\":\"action.editing.copy\"}";
    DesktopActionsActionRun *run =
        desktop_actions_run_create((const uint8_t *)request, strlen(request), 0, 0);
    assert(run);
    DesktopActionsJson *instruction = desktop_actions_run_next(run);
    assert(desktop_actions_json_view(instruction).code == 0);
    const char *success = "{\"status\":\"success\"}";
    assert(desktop_actions_run_record(run, 1, (const uint8_t *)success, strlen(success), 0.25, 1) ==
           0);
    DesktopActionsJson *terminal = desktop_actions_run_next(run);
    DesktopActionsJsonView view = desktop_actions_json_view(terminal);
    assert(view.code == 0 && view.data && view.length == 4 && memcmp(view.data, "null", 4) == 0);
    desktop_actions_json_destroy(terminal);
    DesktopActionsJson *owner = desktop_actions_run_report(run);
    desktop_actions_run_destroy(run);
    desktop_actions_run_destroy(NULL);
    view = desktop_actions_json_view(instruction);
    assert(view.code == 0 && view.data && view.length > 0 && view.data[0] == '{');
    desktop_actions_json_destroy(instruction);
    view = desktop_actions_json_view(owner);
    assert(view.code == 0 && view.data && view.length > 0);
    char *copy = malloc(view.length + 1);
    assert(copy);
    memcpy(copy, view.data, view.length);
    copy[view.length] = 0;
    desktop_actions_json_destroy(owner);
    assert(strstr(copy, "\"status\":\"success\""));
    free(copy);

    const char *steps = "[]";
    DesktopActionsActionRun *empty =
        desktop_actions_run_create((const uint8_t *)steps, strlen(steps), 1, 1);
    assert(empty);
    desktop_actions_run_destroy(empty);
}

static void semantic_editing_contract(void) {
    const struct {
        const char *request;
        const char *key_code[2];
    } cases[] = {
        {"{\"kind\":\"action.editing.select-all\"}", {"\"keyCode\":0", "\"keyCode\":65"}},
        {"{\"kind\":\"action.editing.find-in-app\"}", {"\"keyCode\":3", "\"keyCode\":70"}},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        const char *request = cases[i].request;
        char envelope[96];
        int length = snprintf(envelope, sizeof(envelope), "{\"version\":1,\"action\":%s}", request);
        assert(length > 0 && (size_t)length < sizeof(envelope));
        DesktopActionsJson *owner =
            desktop_actions_action_normalize((const uint8_t *)envelope, (size_t)length, 1);
        DesktopActionsJsonView view = desktop_actions_json_view(owner);
        assert(view.code == 0 && view.data && view.length == (size_t)length);
        assert(memcmp(view.data, envelope, view.length) == 0);
        desktop_actions_json_destroy(owner);

        for (uint32_t platform = 0; platform < 2; ++platform) {
            owner =
                desktop_actions_action_plan((const uint8_t *)request, strlen(request), platform);
            view = desktop_actions_json_view(owner);
            assert(view.code == 0 && view.data && view.length > 0);
            char *copy = malloc(view.length + 1);
            assert(copy);
            memcpy(copy, view.data, view.length);
            copy[view.length] = 0;
            desktop_actions_json_destroy(owner);
            assert(strstr(copy, cases[i].key_code[platform]));
            assert(strstr(copy, platform == 0 ? "\"modifiers\":1" : "\"modifiers\":8"));
            assert((strstr(copy, "accessibility-key-event") != NULL) == (platform == 0));
            free(copy);
        }
    }
}

static void result_codecs(void) {
    const char *spec =
        "{\"code\":\"native-failed\",\"diagnosticMessage\":\"  \",\"nativeCode\":87}";
    DesktopActionsJson *owner = desktop_actions_error_create((const uint8_t *)spec, strlen(spec));
    DesktopActionsJsonView view = desktop_actions_json_view(owner);
    assert(view.code == 0);
    uint8_t *copy = malloc(view.length);
    assert(copy);
    memcpy(copy, view.data, view.length);
    size_t length = view.length;
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_result_normalize(copy, length, 0);
    assert(desktop_actions_json_view(owner).code == 0);
    desktop_actions_json_destroy(owner);
    free(copy);
    const char *duplicate = "{\"status\":\"success\",\"status\":\"success\"}";
    owner = desktop_actions_result_normalize((const uint8_t *)duplicate, strlen(duplicate), 1);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_execution_report_create((const uint8_t *)"[]", 2);
    assert(desktop_actions_json_view(owner).code == 0);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_result_normalize((const uint8_t *)"{}", 2, 99);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_result_normalize(NULL, 0, 0);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_error_create(NULL, SIZE_MAX);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_execution_report_create(NULL, SIZE_MAX);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
}

static void windows_lifetime_without_effects(void) {
    const char *action = "{\"kind\":\"action.editing.copy\"}";
    assert(desktop_actions_windows_create_for_target((const uint8_t *)action, strlen(action),
                                                     NULL) == NULL);
    desktop_actions_windows_target_destroy(NULL);
#ifndef _WIN32
    assert(desktop_actions_windows_target_capture() == NULL);
#endif
    DesktopActionsWindowsRun *run =
        desktop_actions_windows_create((const uint8_t *)action, strlen(action));
    assert(run);
    desktop_actions_windows_cancel(run);
    DesktopActionsJson *owner = desktop_actions_windows_execute(run);
    DesktopActionsJsonView view = desktop_actions_json_view(owner);
    const char *cancelled = "{\"status\":\"cancelled\"}";
    assert(view.code == 0 && view.length == strlen(cancelled));
    assert(memcmp(view.data, cancelled, view.length) == 0);
    desktop_actions_json_destroy(owner);
    owner = desktop_actions_windows_execute(run);
    assert(desktop_actions_json_view(owner).code == 1);
    desktop_actions_json_destroy(owner);
    desktop_actions_windows_destroy(run);
    desktop_actions_windows_cancel(NULL);
    desktop_actions_windows_destroy(NULL);
    assert(desktop_actions_windows_create(NULL, 0) == NULL);
}

static void ordered_sequences(void) {
    assert(desktop_actions_sequence_create(2, 99) == NULL);
    assert(desktop_actions_sequence_next(NULL) == 0);
    assert(desktop_actions_sequence_record(NULL, 1, 1) != 0);
    assert(desktop_actions_sequence_summary(NULL).status == UINT32_MAX);
    desktop_actions_sequence_cancel(NULL);
    desktop_actions_sequence_destroy(NULL);
    DesktopActionsActionSequence *sequence = desktop_actions_sequence_create(2, 1);
    assert(sequence);
    assert(desktop_actions_sequence_record(sequence, 1, 1) != 0);
    assert(desktop_actions_sequence_next(sequence) == 1);
    assert(desktop_actions_sequence_next(sequence) == 0);
    assert(desktop_actions_sequence_record(sequence, 1, 99) != 0);
    assert(desktop_actions_sequence_record(sequence, 2, 1) != 0);
    assert(desktop_actions_sequence_record(sequence, 1, 2) == 0);
    assert(desktop_actions_sequence_next(sequence) == 2);
    assert(desktop_actions_sequence_record(sequence, 2, 1) == 0);
    DesktopActionsSequenceSummary summary = desktop_actions_sequence_summary(sequence);
    assert(summary.status == 1 && summary.recorded_count == 2 && !summary.all_actions_succeeded);
    desktop_actions_sequence_cancel(sequence);
    assert(desktop_actions_sequence_summary(sequence).status == 1);
    desktop_actions_sequence_destroy(sequence);
    sequence = desktop_actions_sequence_create(2, 1);
    assert(desktop_actions_sequence_next(sequence) == 1);
    assert(desktop_actions_sequence_record(sequence, 1, 5) == 0);
    assert(desktop_actions_sequence_next(sequence) == 0);
    assert(desktop_actions_sequence_summary(sequence).status == 4);
    desktop_actions_sequence_destroy(sequence);
}

int main(void) {
    ordered_sequences();
    assert(desktop_actions_abi_version() == DESKTOP_ACTIONS_ABI_VERSION);
    assert(sizeof(DesktopActionsKeyStroke) == 4 && sizeof(DesktopActionsKeyResult) == 8);
    assert(sizeof(DesktopActionsJsonView) == 32 && offsetof(DesktopActionsJsonView, data) == 16);
    DesktopActionsJson *catalog = desktop_actions_catalog();
    DesktopActionsJsonView view = desktop_actions_json_view(catalog);
    assert(view.code == 0 && view.length > 0 && view.data[0] == '[');
    desktop_actions_json_destroy(catalog);
    canonical_json();
    text_input();
    input_metadata();
    planning();
    macos_editing_chord();
    semantic_editing_contract();
    action_run_ownership();
    windows_lifetime_without_effects();
    result_codecs();
    const char *shortcut = "ctrl-page-down";
    DesktopActionsKeyResult key =
        desktop_actions_parse_shortcut((const uint8_t *)shortcut, strlen(shortcut));
    assert(key.code == 0 && key.stroke.usage == 0x4e && key.stroke.modifiers == 8);
    assert(desktop_actions_macos_key_code(key.stroke.usage) == 0x79);
    assert(desktop_actions_macos_key_code(0xffff) == -1);
    const char *media = "action.media.play-pause";
    assert(desktop_actions_system_key((const uint8_t *)media, strlen(media), 0) == 16);
    assert(desktop_actions_system_key((const uint8_t *)media, strlen(media), 1) == 0xb3);
    assert(desktop_actions_system_key((const uint8_t *)media, strlen(media), 99) == -1);
    assert(desktop_actions_system_key(NULL, 0, 0) == -1);
    assert(desktop_actions_execution_create(0, 10) == NULL);
    assert(desktop_actions_execution_create(1, 0) == NULL);
    DesktopActionsExecutionPool *pool = desktop_actions_execution_create(1, 10);
    assert(pool);
    uint64_t id = desktop_actions_execution_reserve(pool, 1, 0);
    assert(id != 0 && desktop_actions_execution_deadline(pool, id) == 11);
    assert(desktop_actions_execution_timeout(pool, id, 12) == 3);
    assert(desktop_actions_execution_reserve(pool, 12, 0) == 0);
    assert(desktop_actions_execution_finish(pool, id, 12) == 0);
    id = desktop_actions_execution_reserve(pool, 12, 0);
    assert(id != 0 && desktop_actions_execution_finish(pool, id, 13) == 1);
    assert(desktop_actions_execution_finish(pool, id, 12) == 0);
    desktop_actions_execution_destroy(pool);
    desktop_actions_execution_destroy(NULL);
    return 0;
}
