#ifndef SIMO_AVI_H
#define SIMO_AVI_H
/// Copies the first video and audio streams into a temporary local QuickTime movie.
/// Returns zero on success. The caller owns both paths and cleans up partial output.
int simo_remux_avi(const char *source, const char *destination, int (*cancelled)(void));
#endif
