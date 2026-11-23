#ifndef DESKTOP_ACTIONS_H
#define DESKTOP_ACTIONS_H
#include <stdint.h>
#include <stddef.h>
#define DESKTOP_ACTIONS_ABI_VERSION 6U
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint16_t usage, modifiers;
} DesktopActionsKeyStroke;
typedef struct {
    uint32_t code;
    DesktopActionsKeyStroke stroke;
} DesktopActionsKeyResult;
typedef struct {
    uint16_t letter, key_code, modifiers;
} DesktopActionsMacosEditingChord;
typedef struct DesktopActionsExecutionPool DesktopActionsExecutionPool;
typedef struct DesktopActionsActionSequence DesktopActionsActionSequence;
typedef struct DesktopActionsActionRun DesktopActionsActionRun;
typedef struct DesktopActionsWindowsRun DesktopActionsWindowsRun;
typedef struct DesktopActionsWindowsTarget DesktopActionsWindowsTarget;
typedef struct DesktopActionsJson DesktopActionsJson;
/* Code 0: canonical JSON; 1: invalid data; 2: unsupported envelope version; 3: unknown action.
 * For errors, data is UTF-8 diagnostic text. Version is meaningful only when has_version is
 * nonzero. Views borrow the owner. Copy bytes before destruction; no caller frees a view's data
 * pointer. */
typedef struct {
    uint32_t code, has_version;
    int64_t version;
    const uint8_t *data;
    size_t length;
} DesktopActionsJsonView;
uint32_t desktop_actions_abi_version(void);
/* Entries include supportedPlatforms, derived from Rust plans. This does not
 * establish valid caller input, permissions, installed targets or effect success. */
DesktopActionsJson *desktop_actions_catalog(void);
/* Pure input evaluation; shortcut catalogs and directory observations are supplied by the host. */
DesktopActionsJson *desktop_actions_text_input_evaluate(const uint8_t *data, size_t length);
DesktopActionsJson *desktop_actions_action_normalize(const uint8_t *data, size_t length,
                                                     uint32_t envelope);
DesktopActionsJson *desktop_actions_input_normalize(const uint8_t *data, size_t length);
/* Kind 0: input parameter; 1: input descriptor. Normalize labels and example data. */
DesktopActionsJson *desktop_actions_input_metadata_normalize(const uint8_t *data, size_t length,
                                                             uint32_t kind);
/* Shared result codec: 0 error, 1 result, 2 attempt, 3 outcome. Original bytes,
 * including nested fields and duplicate keys, are validated before normalization. */
DesktopActionsJson *desktop_actions_result_normalize(const uint8_t *data, size_t length,
                                                     uint32_t kind);
/* ErrorSpec factory; normalizes diagnostics and supplies blank-message defaults. */
DesktopActionsJson *desktop_actions_error_create(const uint8_t *data, size_t length);
/* Attempt array factory; Rust derives finalResult and handles an empty history. */
DesktopActionsJson *desktop_actions_execution_report_create(const uint8_t *data, size_t length);
/* Platform 0: macOS; 1: Windows. Pure planning/inspection; no OS effects.
 * Empty action-plan steps explicitly mean unsupported on the selected platform. */
DesktopActionsJson *desktop_actions_action_plan(const uint8_t *data, size_t length,
                                                uint32_t platform);
/* Preview the same plan JSON for a UTF-8 catalog identifier using the catalog sample. */
DesktopActionsJson *desktop_actions_action_kind_plan(const uint8_t *data, size_t length,
                                                     uint32_t platform);
DesktopActionsJson *desktop_actions_plan_metadata(const uint8_t *data, size_t length,
                                                  uint32_t platform);
DesktopActionsJsonView desktop_actions_json_view(const DesktopActionsJson *owner);
void desktop_actions_json_destroy(DesktopActionsJson *owner);
DesktopActionsKeyResult desktop_actions_parse_shortcut(const uint8_t *data, size_t length);
/* Returns -1 when the physical usage has no supported macOS ANSI key mapping. */
int32_t desktop_actions_macos_key_code(uint16_t usage);
/* A dedicated editing action's lowercase ASCII letter and canonical macOS stroke.
 * Returns zero fields for invalid identifiers and other actions. Planning only. */
DesktopActionsMacosEditingChord desktop_actions_macos_editing_chord(const uint8_t *data,
                                                                    size_t length);
/* Consumer control for a canonical action identifier. Platform 0: macOS NX key,
 * 1: Windows VK. Returns -1 for unknown/unsupported input. Does not post events. */
int32_t desktop_actions_system_key(const uint8_t *data, size_t length, uint32_t platform);
/* Both policy values must be positive; invalid policy returns null without substitution. */
DesktopActionsExecutionPool *desktop_actions_execution_create(size_t maximum, uint64_t timeout_ns);
uint64_t desktop_actions_execution_reserve(const DesktopActionsExecutionPool *pool, uint64_t now_ns,
                                           uint32_t interactive);
uint64_t desktop_actions_execution_deadline(const DesktopActionsExecutionPool *pool, uint64_t id);
/* Terminal code: 0 none, 1 completed, 2 cancelled, 3 timed out. */
uint32_t desktop_actions_execution_cancel(const DesktopActionsExecutionPool *pool, uint64_t id,
                                          uint64_t now_ns);
uint32_t desktop_actions_execution_timeout(const DesktopActionsExecutionPool *pool, uint64_t id,
                                           uint64_t now_ns);
uint32_t desktop_actions_execution_active(const DesktopActionsExecutionPool *pool, uint64_t id);
uint32_t desktop_actions_execution_finish(const DesktopActionsExecutionPool *pool, uint64_t id,
                                          uint64_t now_ns);
void desktop_actions_execution_destroy(DesktopActionsExecutionPool *pool);
/* Ordered requests. Failure behavior: 0 stop on completed failure/skip, 1 continue.
 * Cancellation, timeout and capacity rejection always stop further issuance.
 * Values/reports and effects stay with the caller. Invalid policy returns null. */
typedef struct {
    uint32_t status, all_actions_succeeded;
    size_t recorded_count;
} DesktopActionsSequenceSummary;
DesktopActionsActionSequence *desktop_actions_sequence_create(size_t count,
                                                              uint32_t failure_behavior);
/* One-based identity; 0 when terminal or a request is already outstanding. */
size_t desktop_actions_sequence_next(const DesktopActionsActionSequence *sequence);
/* Result: 1 success, 2 failure, 3 skipped, 4 cancelled, 5 timed out, 6 busy.
 * Returns 0 on acceptance; invalid input does not advance state. */
uint32_t desktop_actions_sequence_record(const DesktopActionsActionSequence *sequence, size_t id,
                                         uint32_t result);
void desktop_actions_sequence_cancel(const DesktopActionsActionSequence *sequence);
/* Status: 0 running, 1 completed, 2 stopped on failure, 3 cancelled, 4 timed out,
 * 5 busy. Completed means every delivery was recorded, not every effect succeeded.
 * Null produces UINT32_MAX and false, never a successful empty sequence. */
DesktopActionsSequenceSummary
desktop_actions_sequence_summary(const DesktopActionsActionSequence *sequence);
void desktop_actions_sequence_destroy(DesktopActionsActionSequence *sequence);
/* Owned plan/result reducer. No native effects or callbacks occur under its lock.
 * Platform 0: macOS; 1: Windows. Input kind 0: action; 1: tagged step array. */
DesktopActionsActionRun *desktop_actions_run_create(const uint8_t *data, size_t length,
                                                    uint32_t platform, uint32_t input_kind);
/* Owned JSON: null when complete, otherwise {id,step}. */
DesktopActionsJson *desktop_actions_run_next(const DesktopActionsActionRun *run);
/* Returns zero on acceptance. Invalid data/id/duration does not advance the run. */
uint32_t desktop_actions_run_record(const DesktopActionsActionRun *run, uint64_t id,
                                    const uint8_t *data, size_t length, double duration_seconds,
                                    uint32_t has_duration);
DesktopActionsJson *desktop_actions_run_report(const DesktopActionsActionRun *run);
void desktop_actions_run_destroy(DesktopActionsActionRun *run);
/* Owned Windows execution. Creation copies a validated action; execute may run
 * once and blocks until worker acknowledgement. Cancellation is thread-safe but
 * cannot undo an OS effect. Non-Windows execution reports unsupported-action.
 * JSON: {status:"completed",outcome:...} or {status:"cancelled"}. */
DesktopActionsWindowsRun *desktop_actions_windows_create(const uint8_t *data, size_t length);
/* Capture owns an observation and returns null when unavailable or incomplete.
 * A target is read-only and may be used to create multiple runs. Destroy it only
 * after every create call using it has returned. A run retains its own snapshot. */
DesktopActionsWindowsTarget *desktop_actions_windows_target_capture(void);
void desktop_actions_windows_target_destroy(DesktopActionsWindowsTarget *target);
/* Null target or invalid action returns null. Execution checks the captured
 * foreground target and reports native-failed when the target changed. */
DesktopActionsWindowsRun *
desktop_actions_windows_create_for_target(const uint8_t *data, size_t length,
                                          const DesktopActionsWindowsTarget *target);
void desktop_actions_windows_cancel(const DesktopActionsWindowsRun *run);
DesktopActionsJson *desktop_actions_windows_execute(const DesktopActionsWindowsRun *run);
void desktop_actions_windows_destroy(DesktopActionsWindowsRun *run);
#ifdef __cplusplus
}
#endif
#endif
