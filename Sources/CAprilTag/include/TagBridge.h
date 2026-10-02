#ifndef RD_TAG_BRIDGE_H
#define RD_TAG_BRIDGE_H
#include <stdint.h>
typedef struct rd_tag_detector rd_tag_detector;
rd_tag_detector *rd_tag_create(void);
void rd_tag_destroy(rd_tag_detector *d);
int rd_tag_detect(rd_tag_detector *d, const uint8_t *gray, int width, int height, double size, double fx, double fy, double cx, double cy);
double rd_tag_value(rd_tag_detector *d, int index, int field);
#endif
