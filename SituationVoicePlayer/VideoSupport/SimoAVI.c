#include "SimoAVI.h"
#include <libavformat/avformat.h>
#include <libavutil/error.h>

// AVI files may omit presentation timestamps. Let the demuxer recover timestamps
// before switching containers; compressed pictures and audio are never re-encoded.
int simo_remux_avi(const char *source, const char *destination, int (*cancelled)(void)) {
    AVFormatContext *input = NULL, *output = NULL;
    AVPacket *packet = NULL;
    int streams[2], mapped[2] = {-1, -1};
    int result = avformat_open_input(&input, source, av_find_input_format("avi"), NULL);
    if (result < 0) goto done;
    input->flags |= AVFMT_FLAG_GENPTS;
    if ((result = avformat_find_stream_info(input, NULL)) < 0) goto done;
    streams[0] = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    streams[1] = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (streams[0] < 0) { result = AVERROR_STREAM_NOT_FOUND; goto done; }
    if ((result = avformat_alloc_output_context2(&output, NULL, "mov", destination)) < 0) goto done;
    for (int i = 0; i < 2; ++i) {
        if (streams[i] < 0) continue;
        AVStream *from = input->streams[streams[i]];
        AVStream *to = avformat_new_stream(output, NULL);
        if (!to) { result = AVERROR(ENOMEM); goto done; }
        if ((result = avcodec_parameters_copy(to->codecpar, from->codecpar)) < 0) goto done;
        to->codecpar->codec_tag = 0;
        to->time_base = from->time_base;
        to->avg_frame_rate = from->avg_frame_rate;
        mapped[i] = to->index;
    }
    if ((result = avio_open(&output->pb, destination, AVIO_FLAG_WRITE)) < 0) goto done;
    if ((result = avformat_write_header(output, NULL)) < 0) goto done;
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto done; }
    while ((result = av_read_frame(input, packet)) >= 0) {
        if (cancelled && cancelled()) { result = AVERROR_EXIT; goto done; }
        int i = packet->stream_index == streams[0] ? 0 : packet->stream_index == streams[1] ? 1 : -1;
        if (i >= 0) {
            av_packet_rescale_ts(packet, input->streams[streams[i]]->time_base,
                                 output->streams[mapped[i]]->time_base);
            packet->stream_index = mapped[i];
            packet->pos = -1;
            if ((result = av_interleaved_write_frame(output, packet)) < 0) goto done;
        }
        av_packet_unref(packet);
    }
    if (result == AVERROR_EOF) result = av_write_trailer(output);
done:
    av_packet_free(&packet);
    if (output && output->pb) {
        int closed = avio_closep(&output->pb);
        if (result >= 0 && closed < 0) result = closed;
    }
    avformat_free_context(output);
    avformat_close_input(&input);
    return result;
}
