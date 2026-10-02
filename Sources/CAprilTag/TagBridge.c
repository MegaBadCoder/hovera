#include "TagBridge.h"
#include "apriltag.h"
#include "apriltag_pose.h"
#include "tag36h11.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
struct rd_tag_detector { apriltag_detector_t *detector; apriltag_family_t *family; int count; double values[16][24]; };
rd_tag_detector *rd_tag_create(void) {
    rd_tag_detector *d=calloc(1,sizeof(*d));
    if (!d) return NULL;
    d->family=tag36h11_create(); d->detector=apriltag_detector_create();
    apriltag_detector_add_family_bits(d->detector,d->family,0);
    d->detector->nthreads=2; d->detector->quad_decimate=1; d->detector->refine_edges=true;
    return d;
}
void rd_tag_destroy(rd_tag_detector *d) {
    if (!d) return;
    apriltag_detector_destroy(d->detector);tag36h11_destroy(d->family);free(d);
}
static void free_pose(apriltag_pose_t p) { matd_destroy(p.R);matd_destroy(p.t); }
int rd_tag_detect(rd_tag_detector *d,const uint8_t *gray,int w,int h,double size,double fx,double fy,double cx,double cy) {
    d->count=0;
    if (!gray || w<16 || h<16 || !(size>0 && fx>0 && fy>0)) return 0;
    image_u8_t image={.width=w,.height=h,.stride=w,.buf=(uint8_t *)gray};
    zarray_t *detections=apriltag_detector_detect(d->detector,&image);
    for (int i=0;i<zarray_size(detections) && d->count<16;i++) {
        apriltag_detection_t *tag;zarray_get(detections,i,&tag);
        if (tag->id<0 || tag->id>2 || tag->hamming!=0 || tag->decision_margin<30) continue;
        double edge=1e9;
        bool clipped=false;
        for(int k=0;k<4;k++) {
            int n=(k+1)%4;
            edge=fmin(edge,hypot(tag->p[k][0]-tag->p[n][0],tag->p[k][1]-tag->p[n][1]));
            if(tag->p[k][0]<3 || tag->p[k][0]>w-3 || tag->p[k][1]<3 || tag->p[k][1]>h-3) clipped=true;
        }
        if(edge<18 || clipped)continue;
        apriltag_detection_info_t info={tag,size,fx,fy,cx,cy};
        apriltag_pose_t a={0},b={0};double ea,eb;
        estimate_tag_pose_orthogonal_iteration(&info,&ea,&a,&eb,&b,30);
        apriltag_pose_t best=ea<=eb?a:b;
        double error=fmin(ea,eb);
        bool valid=best.R && best.t && isfinite(error) && error<size*size*0.01;
        if(valid && a.R && b.R) {
            double trace=0;for(int k=0;k<9;k++)trace+=a.R->data[k]*b.R->data[k];
            double angle=acos(fmax(-1,fmin(1,(trace-1)/2)));
            if(angle>15*M_PI/180 && fmax(ea,eb)>1e-12 && fmin(ea,eb)/fmax(ea,eb)>0.9)valid=false;
        }
        if(valid && best.t->data[2]>.1 && best.t->data[2]<3) {
            double *v=d->values[d->count++];v[0]=tag->id;v[1]=tag->decision_margin;v[2]=tag->hamming;v[3]=error;
            memcpy(v+4,best.R->data,9*sizeof(double));memcpy(v+13,best.t->data,3*sizeof(double));
            for(int k=0;k<4;k++){v[16+k*2]=tag->p[k][0];v[17+k*2]=tag->p[k][1];}
        }
        free_pose(a);free_pose(b);
    }
    apriltag_detections_destroy(detections);return d->count;
}
double rd_tag_value(rd_tag_detector *d,int i,int f){return i>=0&&i<d->count&&f>=0&&f<24?d->values[i][f]:NAN;}
