#include <stdlib.h>
#include <stdatomic.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <string.h>
#include <stdio.h>

static dispatch_semaphore_t pose_entered;
static dispatch_semaphore_t pose_release;
static atomic_int block_pose;
static atomic_int pose_active;
static atomic_int overlapping_control;
static int trace;
static int failure;
static int pose_mode;
static float pose_position[3];
static float reset_position_x;
static float film = 0.75f;
static int film_writes;
static void (*imu_callback)(float *, double);
static void (*pose_callback)(float *, double);
static double native_request;
static atomic_int native_calls;
static float native_angle;
static int native_status = 2;
static char custom_config[512];

void test_emit_pose(double time) { float matrix[16] = {0}; if (pose_callback) pose_callback(matrix, time); }
double test_native_request(void) { return native_request; }
int test_native_calls(void) { return atomic_load(&native_calls); }
const char *test_custom_config(void) { return custom_config; }
void test_native_status(int value) { native_status = value; }
void test_native_angle(float value) { native_angle = value; }
static void wait_for_block(void) {
    if (!atomic_exchange(&block_pose, 0)) return;
    atomic_store(&pose_active, 1);
    dispatch_semaphore_signal(pose_entered);
    dispatch_semaphore_wait(pose_release, dispatch_time(DISPATCH_TIME_NOW, 5000000000));
    atomic_store(&pose_active, 0);
}
#ifndef OMIT_NATIVE_POSE
int carina_a1088_viture_get_gl_pose(float *values, double time) {
    atomic_fetch_add(&native_calls, 1);
    wait_for_block();
    native_request = time;
    for (int i = 0; i < 32; i++) values[i] = 0;
    values[0] = cosf(native_angle); values[2] = -sinf(native_angle);
    values[5] = 1; values[8] = sinf(native_angle); values[10] = cosf(native_angle); values[15] = 1;
    values[12] = pose_position[0]; values[13] = pose_position[1]; values[14] = pose_position[2];
    values[30] = native_status;
    return failure == 6 ? -1 : 0;
}
#endif

void test_block_next_pose(void) {
    pose_entered = dispatch_semaphore_create(0);
    pose_release = dispatch_semaphore_create(0);
    atomic_store(&block_pose, 1);
}
int test_wait_for_pose(void) { return (int)dispatch_semaphore_wait(pose_entered, dispatch_time(DISPATCH_TIME_NOW, 2000000000)); }
void test_release_pose(void) { dispatch_semaphore_signal(pose_release); }
int test_overlapping_control(void) { return atomic_load(&overlapping_control); }
int test_trace(void) { return trace; }
void test_failure(int value) { failure = value; }
void test_pose_mode(int value) { pose_mode = value; }
void test_pose_position(float x, float y, float z) { pose_position[0] = x; pose_position[1] = y; pose_position[2] = z; }
float test_reset_position_x(void) { return reset_position_x; }
int test_film_writes(void) { return film_writes; }
float test_film(void) { return film; }
void test_emit_imu(float rate, double time) {
    float values[6] = {0, 0, 9.81f, 0, 0, rate};
    if (imu_callback) imu_callback(values, time);
}
void *xr_device_provider_create(int product) { trace = trace * 10 + 1; return malloc(1); }
int xr_device_provider_initialize(void *h, const char *config, const char *cache) { if (config) snprintf(custom_config, sizeof(custom_config), "%s", config); trace = trace * 10 + 2; return failure == 2 ? -1 : 0; }
int xr_device_provider_start(void *h) {
    trace = trace * 10 + 3;
    if (failure == 7) {
        test_emit_pose(1100);
        dispatch_semaphore_wait(pose_entered, dispatch_time(DISPATCH_TIME_NOW, 100000000));
        return -1;
    }
    return failure == 3 ? -1 : 0;
}
int xr_device_provider_stop(void *h) { if (atomic_load(&pose_active)) atomic_store(&overlapping_control, 1); trace = trace * 10 + 4; return 0; }
int xr_device_provider_shutdown(void *h) { trace = trace * 10 + 5; return 0; }
void xr_device_provider_destroy(void *h) { trace = trace * 10 + 6; free(h); }
int xr_device_provider_get_device_type(void *h) { return 2; }
int xr_device_provider_set_dof_type_carina(void *h, int dof) { return failure == 1 ? -1 : 0; }
int xr_device_provider_get_gl_pose_carina(void *h, float *pose, double predict, int *status) {
    wait_for_block();
    if (pose_mode == 1) return -1;
    for (int i = 0; i < 7; i++) pose[i] = i == 3 ? 1 : 0;
    for (int i = 0; i < 3; i++) pose[i] = pose_position[i];
    *status = pose_mode == 2 ? 1 : 0;
    return 0;
}
int xr_device_provider_reset_origin_carina(void *h, float *pose) { if (atomic_load(&pose_active)) atomic_store(&overlapping_control, 1); reset_position_x = pose[0]; return 0; }
int xr_device_provider_register_callbacks_carina(void *h, void *pose, void *vsync, void (*imu)(float *, double), void *camera) {
    if (failure == 4) return -1;
    imu_callback = imu;
    pose_callback = pose;
    return 0;
}
int xr_device_provider_is_product_id_valid(int product) { return 1; }
int xr_device_provider_get_film_mode(void *h, float *value) { if (failure == 5) return -1; *value = film; return 0; }
int xr_device_provider_set_film_mode(void *h, float value) { if (failure == 5) return -1; film = value; film_writes++; return 0; }
