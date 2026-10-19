#include <obs.h>
#include <obs-module.h>
#include <util/platform.h>
#include <libavcodec/avcodec.h>
#include <stdio.h>
#include <math.h>

static const char *tone_name(void *unused) { return "Verification tone"; }
static void *tone_create(obs_data_t *settings, obs_source_t *source) { return source; }
static void tone_destroy(void *data) { (void)data; }
static struct obs_source_info tone_info = {
    .id = "verification_tone", .type = OBS_SOURCE_TYPE_INPUT, .output_flags = OBS_SOURCE_AUDIO,
    .get_name = tone_name, .create = tone_create, .destroy = tone_destroy,
};
static int stop_code;
static void stopped(void *unused, calldata_t *data) { stop_code = (int)calldata_int(data, "code"); }
static int load_plugin(const char *name)
{
    char dll[512], data[512];
    snprintf(dll, sizeof dll, "../../obs-plugins/64bit/%s.dll", name);
    snprintf(data, sizeof data, "../../data/obs-plugins/%s", name);
    obs_module_t *module = NULL;
    if (obs_open_module(&module, dll, data) != MODULE_SUCCESS || !obs_init_module(module)) return 0;
    return 1;
}
static int record(obs_source_t *tone, int custom, const char *path)
{
    obs_data_t *settings = obs_data_create();
    obs_data_set_string(settings, custom ? "url" : "path", path);
    obs_data_set_string(settings, "format_name", "matroska");
    obs_data_set_string(settings, "video_encoder", "libx264");
    obs_data_set_string(settings, "audio_encoder", "libfdk_aac");
    obs_data_set_string(settings, "video_settings", "preset=ultrafast");
    obs_data_set_int(settings, "video_bitrate", 1000);
    obs_data_set_int(settings, "audio_bitrate", 128);
    obs_data_set_int(settings, "gop_size", 60);
    obs_output_t *output = obs_output_create(custom ? "ffmpeg_output" : "ffmpeg_muxer", "verification", settings, NULL);
    obs_data_release(settings);
    if (!output) return 0;
    obs_encoder_t *video = NULL, *audio = NULL;
    if (!custom) {
        settings = obs_data_create();
        obs_data_set_int(settings, "bitrate", 128);
        audio = obs_audio_encoder_create("libfdk_aac", "FDK verification", settings, 0, NULL);
        obs_data_release(settings);
        settings = obs_data_create();
        obs_data_set_int(settings, "bitrate", 1000);
        obs_data_set_string(settings, "preset", "ultrafast");
        video = obs_video_encoder_create("obs_x264", "x264 verification", settings, NULL);
        obs_data_release(settings);
        if (!audio || !video) return 0;
        obs_encoder_set_audio(audio, obs_get_audio());
        obs_encoder_set_video(video, obs_get_video());
        obs_output_set_audio_encoder(output, audio, 0);
        obs_output_set_video_encoder(output, video);
    } else {
        obs_output_set_media(output, obs_get_video(), obs_get_audio());
        obs_output_set_mixers(output, 1);
    }
    stop_code = 0;
    signal_handler_connect(obs_output_get_signal_handler(output), "stop", stopped, NULL);
    int ok = obs_output_start(output);
    for (int i = 0; ok && i < 500 && !obs_output_active(output); ++i) os_sleep_ms(10);
    ok = ok && obs_output_active(output);
    uint64_t start = os_gettime_ns();
    float samples[2][480];
    for (int chunk = 0; ok && chunk < 300; ++chunk) {
        for (int n = 0; n < 480; ++n)
            samples[0][n] = samples[1][n] = 0.1f * sinf((float)(chunk * 480 + n) * 6.2831853f * 440.0f / 48000.0f);
        struct obs_source_audio frame = {0};
        frame.data[0] = (uint8_t *)samples[0]; frame.data[1] = (uint8_t *)samples[1];
        frame.frames = 480; frame.speakers = SPEAKERS_STEREO;
        frame.format = AUDIO_FORMAT_FLOAT_PLANAR; frame.samples_per_sec = 48000;
        frame.timestamp = start + (uint64_t)chunk * 10000000;
        obs_source_output_audio(tone, &frame);
        os_sleepto_ns(start + (uint64_t)(chunk + 1) * 10000000);
        if (!obs_output_active(output)) ok = 0;
    }
    obs_output_stop(output);
    for (int i = 0; i < 100 && obs_output_active(output); ++i) os_sleep_ms(50);
    ok = ok && stop_code == 0 && obs_output_get_total_frames(output) > 30;
    printf("VERIFY %s result=%s frames=%d stop_code=%d\n", custom ? "custom-fdk" : "standard-fdk", ok ? "PASS" : "FAIL", obs_output_get_total_frames(output), stop_code);
    obs_output_release(output);
    obs_encoder_release(video); obs_encoder_release(audio);
    return ok;
}
int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    const char *encoders[] = {"libfdk_aac", "h264_qsv", "hevc_qsv", "av1_qsv"};
    for (int i = 0; i < 4; ++i) {
        const AVCodec *codec = avcodec_find_encoder_by_name(encoders[i]);
        printf("VERIFY encoder %s: %s\n", encoders[i], codec ? "PASS" : "FAIL");
        if (!codec) return 3;
    }
    if (!obs_startup("en-US", NULL, NULL)) return 4;
    obs_add_data_path("../../data/libobs");
    struct obs_audio_info ai = { .samples_per_sec = 48000, .speakers = SPEAKERS_STEREO };
    if (!obs_reset_audio(&ai)) return 5;
    struct obs_video_info vi = { .graphics_module = "libobs-d3d11", .fps_num = 30, .fps_den = 1,
        .base_width = 640, .base_height = 360, .output_width = 640, .output_height = 360,
        .output_format = VIDEO_FORMAT_NV12, .gpu_conversion = true, .colorspace = VIDEO_CS_709,
        .range = VIDEO_RANGE_PARTIAL, .scale_type = OBS_SCALE_BILINEAR };
    if (obs_reset_video(&vi) != OBS_VIDEO_SUCCESS) return 6;
    if (!load_plugin("obs-ffmpeg") || !load_plugin("obs-libfdk") || !load_plugin("obs-x264")) return 7;
    obs_register_source(&tone_info);
    obs_source_t *tone = obs_source_create("verification_tone", "Tone", NULL, NULL);
    obs_scene_t *scene = obs_scene_create("Verification");
    obs_set_output_source(0, obs_scene_get_source(scene));
    obs_set_output_source(1, tone);
    int first = record(tone, 0, argv[1]);
    int second = record(tone, 1, argv[2]);
    obs_set_output_source(1, NULL); obs_set_output_source(0, NULL);
    obs_source_release(tone); obs_scene_release(scene); obs_shutdown();
    return first && second ? 0 : 8;
}
