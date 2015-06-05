//
//  RTSPClientView.m
//  RTSPClient
//
//  Created by Xshl5 on 12-11-19.
//  Copyright (c) 2012年 com.jhsys. All rights reserved.
//

#import "RTSPClientView.h"
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswscale/swscale.h"
#include "libavutil/imgutils.h"

#include <sys/socket.h>
#include <arpa/inet.h>
#include <signal.h>
#include <sys/time.h>
static volatile int recv_sigpipe_flag = 0;
void recv_sig(int sig)
{
//    recv_sigpipe_flag = 1;
    printf("recv sig SIGPIPE.\n");
}

#define CAMERA_TURN_SERVICE_PORT 6899
#define RTSP_CONN_TIMEOUT 5
#define RTSP_CLOSE_DETECT_INTERVAL_MICSEC 500
enum CAMERAM_TURN_OPERATION
{
    TURN_UP = 0x1111,
    TURN_DOWN = 0x2222,
    TURN_LEFT = 0x3333,
    TURN_RIGHT = 0x4444,
    TURN_STOP = 0x5555,
    TURN_LOOP = 0x6666
};
static inline int camera_turn_internal(int sock, struct sockaddr_in* rtsp_addr, int rtsp_addr_len, int operation_code);
static inline void init_rtsp_addr(struct sockaddr_in* addr, const char* rtsp_url);
static int tcp_connect_test(struct sockaddr_in* addr, const char* rtsp_url);

static int ffmpeg_regiter_flag = 0;

@implementation RTSPClientView
- (id)init
{
    self = [super init];
    if (self) {
        init_width = 0.0f;
        init_height = 0.0f;
        [self rtsp_init];
    }
    
    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code
        init_width = frame.size.width;
        init_height = frame.size.height;
        [self rtsp_init];
    }
    return self;
}

- (void)rtsp_init
{
    need_to_closed = 0;
    rtsp_conn_status = 0;
    
    signal(SIGPIPE, recv_sig);
    rtsp_url = @"rtsp://192.168.2.200:8200/v1.3gp";
    pause_flag = 0;
    
    // sock
    if( (sock = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
        perror("socket");
    //setsockopt
    struct timeval tv = {3, 0};
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const void*)&tv, sizeof(tv));
    
    // rtsp_addr
    rtsp_addr_len = sizeof(struct sockaddr_in);
    rtsp_addr = (struct sockaddr_in*) malloc(rtsp_addr_len);
    memset(rtsp_addr, 0, rtsp_addr_len);
    rtsp_addr->sin_family = AF_INET;
    init_rtsp_addr(rtsp_addr, rtsp_url.UTF8String);
    
    if (ffmpeg_regiter_flag == 0) {
        avcodec_register_all();
        av_register_all();
        avformat_network_init();
        ffmpeg_regiter_flag = 1;
    }
    
}

- (void)dealloc
{
    need_to_closed = 1;
    close(sock);
    free(rtsp_addr);
    [super dealloc];
}

- (int)conn_status
{
    return rtsp_conn_status;
}

- (void)set_rtsp_url: (NSString*) url
{
    rtsp_url = url;
    [rtsp_url retain];
    init_rtsp_addr(rtsp_addr, rtsp_url.UTF8String);
}
- (NSString*)get_rtsp_url
{ 
    return rtsp_url;
}

- (void)rtsp_open:(NSString *) url
{
    [NSThread detachNewThreadSelector:@selector(rtsp_open_inner:) toTarget:self withObject:url];
}
- (void)rtsp_open_inner:(NSString*) url
{
    // rtsp_url == url
    int counter = 0;
    while(rtsp_conn_status != 0 && [ [rtsp_url uppercaseString] isEqualToString: [url uppercaseString] ])
    {
        fprintf(stderr, "URL '%s' has already opened.\n", [url UTF8String]);
        usleep(1000000);
        
        ++counter;
        if(counter >= RTSP_CONN_TIMEOUT)
            return;
        
        continue;
    }
    
    [self set_rtsp_url: url];
    [self rtsp_close];
    
    [self rtsp_open];
}

- (void)rtsp_open
{
    if(rtsp_conn_status != 0)
        return;

    recv_sigpipe_flag = 0;
    need_to_closed = 0;
    rtsp_conn_status = -1; // connecting...
    if(strcasestr(rtsp_url.UTF8String, "rtsp://"))
        [NSThread detachNewThreadSelector:@selector(rtsp_open_internal) toTarget:self withObject:nil];
    else
    {
        [NSThread detachNewThreadSelector:@selector(local_media_open_internal) toTarget:self withObject:nil];
    }
    // [self performSelectorInBackground:@selector(rtsp_open_internal) withObject:nil];
}

// Only override drawRect: if you perform custom drawing.
// An empty implementation adversely affects performance during animation.
//- (void)drawRect:(CGRect)rect
//{
//    printf("adfadjhaskldfjlaskdjflasjd, %f, %f\n", video_image.size.width, video_image.size.height);
//    CGRect myRect;
//    
//    myRect.origin.x = 0.0 ;
//    myRect.origin.y = 0.0;
//    myRect.size = video_image.size;
//    [video_image drawInRect:myRect];
//}

- (void)rtsp_open_internal
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    AVFormatContext* pFormatCtx;
    AVCodecContext* pCodecCtx;
    AVCodec* pCodec;
    AVFrame* pFrame, *pFrameRGB;
    AVPacket packet;
    int videoStream = -1, frameFinished = -1;
    int i= 0, numBytes = 0;
    uint8_t* buffer;
    
    enum AVPixelFormat src_pix_fmt = AV_PIX_FMT_YUV420P, dst_pix_fmt = AV_PIX_FMT_RGB24;
    struct SwsContext* sws_ctx;
    int src_w = 0, src_h = 0;
    int dst_w = 0, dst_h = 0;
    
    if(rtsp_conn_status == -1)
    {
        if( tcp_connect_test(rtsp_addr, rtsp_url.UTF8String) == 0 )
        {
            printf("Couldn't connect to RTSPServer, Connection timed out.\n");
            goto func_end;
        }
        
        // Open video file
        pFormatCtx = avformat_alloc_context();
        // Supports rtsp over tcp mode
        AVDictionary* option = NULL;
        char open_url[512] = {0}; memset(open_url, 0, sizeof(open_url));
        if(strlen(rtsp_url.UTF8String) <= sizeof(open_url)-1)
            strcpy(open_url, rtsp_url.UTF8String);
        else
            strncpy(open_url, rtsp_url.UTF8String, sizeof(open_url)-1);
        
        if(strcasestr(open_url, "?tcp"))
        {
            av_dict_set(&option, "rtsp_transport", "tcp", 0);
            *strcasestr(open_url, "?tcp") = 0;
        }
        
        if(avformat_open_input(&pFormatCtx, open_url, NULL, &option)!=0)
        {
            printf("Couldn't open file\n");
            goto func_end; // Couldn't open file
        }
        
        rtsp_conn_status = 1;
        // Retrieve stream information
        if(avformat_find_stream_info(pFormatCtx, NULL)<0)
        {
            printf("Couldn't find stream information\n");
            goto func_end; // Couldn't find stream information
        }
        
        // Dump information about file onto standard error
        //av_dump_format(pFormatCtx, 0, rtsp_url.UTF8String, 0);
        
        // Find the first video stream
        videoStream=-1;
        for(i=0; i<pFormatCtx->nb_streams; i++)
            if(pFormatCtx->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) {
                videoStream=i;
                break;
            }
        if(videoStream==-1)
        {
            printf("Didn't find a video stream\n");
            goto func_end; // Didn't find a video stream
        }
        
        // Get a pointer to the codec context for the video stream
        pCodecCtx=pFormatCtx->streams[videoStream]->codec;
        
        // Find the decoder for the video stream
        pCodec=avcodec_find_decoder(pCodecCtx->codec_id);
        if(pCodec==NULL) {
            fprintf(stderr, "Unsupported codec!\n");
            goto func_end; // Codec not found
        }
        // Open codec (if it has not opened yet.)
        if(avcodec_is_open(pCodecCtx) == 0 && avcodec_open2(pCodecCtx, pCodec, NULL) != 0)
            goto func_end; // Could not open codec
        
        // Allocate video frame
        pFrame=avcodec_alloc_frame();
        
        // Allocate an AVFrame structure
        pFrameRGB=avcodec_alloc_frame();
        if(pFrameRGB==NULL)
            goto func_end;
        
        // Determine required buffer size and allocate buffer
        numBytes=avpicture_get_size(AV_PIX_FMT_RGB24, pCodecCtx->width,
                                    pCodecCtx->height);
        buffer=(uint8_t *)av_malloc(numBytes*sizeof(uint8_t));
        
        // Assign appropriate parts of buffer to image planes in pFrameRGB
        // Note that pFrameRGB is an AVFrame, but AVFrame is a superset
        // of AVPicture
        avpicture_fill((AVPicture *)pFrameRGB, buffer, AV_PIX_FMT_RGB24,
                       pCodecCtx->width, pCodecCtx->height);
        
        /* create scaling context */
        src_pix_fmt = pCodecCtx->pix_fmt;
        src_w = dst_w = pCodecCtx->width;
        src_h = dst_h = pCodecCtx->height;
        dst_pix_fmt = AV_PIX_FMT_RGB24;
        sws_ctx = sws_getContext(src_w, src_h, src_pix_fmt,
                                 dst_w, dst_h, dst_pix_fmt,
                                 SWS_BICUBIC, NULL, NULL, NULL);
        if (!sws_ctx) {
            fprintf(stderr,
                    "Impossible to create scale context for the conversion "
                    "fmt:%s s:%dx%d -> fmt:%s s:%dx%d\n",
                    av_get_pix_fmt_name(src_pix_fmt), src_w, src_h,
                    av_get_pix_fmt_name(dst_pix_fmt), dst_w, dst_h);
            goto func_end;
        }
        
        while(1) {
            
            if(pause_flag == 1)
            {
                usleep(10000);
                continue;
            };
            
            if(recv_sigpipe_flag != 0 || need_to_closed != 0)
                break;
            if(av_read_frame(pFormatCtx, &packet) < 0)
            {
                av_free_packet(&packet);
                break;
            }
            
            // Is this a packet from the video stream?
            if(packet.stream_index == videoStream) {
                avcodec_decode_video2(pCodecCtx, pFrame, &frameFinished,
                                      &packet);
                
                // Did we get a video frame?
                if(frameFinished) {
                    sws_scale(sws_ctx, (const uint8_t* const*)pFrame->data, pFrame->linesize, 0, pFrame->height,
                              pFrameRGB->data, pFrameRGB->linesize);
                    
                    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
                    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, pFrameRGB->data[0], dst_w*dst_h*3, kCFAllocatorNull);
                    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
                    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                    CGImageRef cgimage = CGImageCreate(dst_w, dst_h, 8, 24, dst_w*3, colorSpace, bitmapInfo, provider, NULL, YES, kCGRenderingIntentDefault);
                    
                    video_image = [[UIImage alloc] initWithCGImage:cgimage];
                    [self performSelectorOnMainThread:@selector(play:) withObject:video_image waitUntilDone:YES];
                    [video_image release];
                    
                    CGImageRelease(cgimage);
                    CGColorSpaceRelease(colorSpace);
                    CGDataProviderRelease(provider);
                    CFRelease(data);
                    
                    frameFinished = 0;
                }
            }
            
            // Free the packet that was allocated by av_read_frame
            av_free_packet(&packet);
        }
        
        // Free the RGB image
//        av_free(buffer);
        av_free(pFrameRGB);
        
        // Free the YUV frame
        av_free(pFrame);
        
        // Close the codec
//        avcodec_close(pCodecCtx);
        
        // Close the video file
        avformat_close_input(&pFormatCtx);
    }
    else
    {
        [pool release];
        return;
    }

func_end:
    rtsp_conn_status = 0;
    [pool release];
}

- (void)local_media_open_internal
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    AVFormatContext* pFormatCtx;
    AVCodecContext* pCodecCtx;
    AVCodec* pCodec;
    AVFrame* pFrame, *pFrameRGB;
    AVPacket packet;
    int videoStream = -1, frameFinished = -1;
    int i= 0, numBytes = 0;
    uint8_t* buffer;
    
    enum AVPixelFormat src_pix_fmt = AV_PIX_FMT_YUV420P, dst_pix_fmt = AV_PIX_FMT_RGB24;
    struct SwsContext* sws_ctx;
    int src_w = 0, src_h = 0;
    int dst_w = 0, dst_h = 0;
    
    if(rtsp_conn_status == -1)
    {
        // Open video file
        pFormatCtx = avformat_alloc_context();
        if(avformat_open_input(&pFormatCtx, rtsp_url.UTF8String, NULL, NULL)!=0)
        {
            printf("Couldn't open file\n");
            goto func_end; // Couldn't open file
        }
        
        rtsp_conn_status = 1;
        // Retrieve stream information
        if(avformat_find_stream_info(pFormatCtx, NULL)<0)
        {
            printf("Couldn't find stream information\n");
            goto func_end; // Couldn't find stream information
        }
        
        // Dump information about file onto standard error
//        av_dump_format(pFormatCtx, 0, rtsp_url.UTF8String, 0);
        
        // Find the first video stream
        videoStream=-1;
        for(i=0; i<pFormatCtx->nb_streams; i++)
            if(pFormatCtx->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO) {
                videoStream=i;
                break;
            }
        if(videoStream==-1)
        {
            printf("Didn't find a video stream\n");
            goto func_end; // Didn't find a video stream
        }
        
        // Get a pointer to the codec context for the video stream
        pCodecCtx=pFormatCtx->streams[videoStream]->codec;
        
        // Find the decoder for the video stream
        pCodec=avcodec_find_decoder(pCodecCtx->codec_id);
        if(pCodec==NULL) {
            fprintf(stderr, "Unsupported codec!\n");
            goto func_end; // Codec not found
        }
        // Open codec (if it has not opened yet.)
        if(avcodec_is_open(pCodecCtx) == 0 && avcodec_open2(pCodecCtx, pCodec, NULL) != 0)
            goto func_end; // Could not open codec
        
        // Allocate video frame
//        pFrame=avcodec_alloc_frame();
        
        // Allocate an AVFrame structure
        pFrameRGB=avcodec_alloc_frame();
        if(pFrameRGB==NULL)
            goto func_end;
        
        // Determine required buffer size and allocate buffer
        numBytes=avpicture_get_size(AV_PIX_FMT_RGB24, pCodecCtx->width,
                                    pCodecCtx->height);
        buffer=(uint8_t *)av_malloc(numBytes*sizeof(uint8_t));
        
        // Assign appropriate parts of buffer to image planes in pFrameRGB
        // Note that pFrameRGB is an AVFrame, but AVFrame is a superset
        // of AVPicture
        avpicture_fill((AVPicture *)pFrameRGB, buffer, AV_PIX_FMT_RGB24,
                       pCodecCtx->width, pCodecCtx->height);
        
        /* create scaling context */
        src_pix_fmt = pCodecCtx->pix_fmt;
        src_w = dst_w = pCodecCtx->width;
        src_h = dst_h = pCodecCtx->height;
        dst_pix_fmt = AV_PIX_FMT_RGB24;
        sws_ctx = sws_getContext(src_w, src_h, src_pix_fmt,
                                 dst_w, dst_h, dst_pix_fmt,
                                 SWS_BICUBIC, NULL, NULL, NULL);
        if (!sws_ctx) {
            fprintf(stderr,
                    "Impossible to create scale context for the conversion "
                    "fmt:%s s:%dx%d -> fmt:%s s:%dx%d\n",
                    av_get_pix_fmt_name(src_pix_fmt), src_w, src_h,
                    av_get_pix_fmt_name(dst_pix_fmt), dst_w, dst_h);
            goto func_end;
        }
        
        [self init_play_frame_list];
        play_frame_list.dst_h = dst_h;
        play_frame_list.dst_w = dst_w;
        play_frame_list.sws_ctx = sws_ctx;
        play_frame_list.pFrameRGB = pFrameRGB;
        double media_fps = (double)1 / av_q2d(pFormatCtx->streams[videoStream]->time_base);
        play_frame_list.frame_interval = 1000000/media_fps;
        while(1) {
            
            if(recv_sigpipe_flag != 0 || need_to_closed != 0)
                break;
            
            if(pause_flag == 1)
            {
                usleep(10000);
                continue;
            };
            if(play_frame_list.size >= 1)
            {
                usleep(100);
                continue;
            }
            
            if(av_read_frame(pFormatCtx, &packet) < 0)
            {
                av_free_packet(&packet);
                break;
            }
            
            // Is this a packet from the video stream?
            pFrame=avcodec_alloc_frame();
            if(packet.stream_index == videoStream) {
                avcodec_decode_video2(pCodecCtx, pFrame, &frameFinished,
                                      &packet);
                
                // Did we get a video frame?
                if(frameFinished) {
                    [self push_back_play_frame_list:pFrame];
                    if(play_frame_list.thread_running_flag == 0)
                        [NSThread detachNewThreadSelector:@selector(local_media_play_thread) toTarget:self withObject:nil];
                    
                    frameFinished = 0;
                }
                else
                    av_free(pFrame);
            }
            
            // Free the packet that was allocated by av_read_frame
            av_free_packet(&packet);
        }
        
        play_frame_list.thread_running_flag = 0;
        // Free the RGB image
        //        av_free(buffer);
        av_free(pFrameRGB);
        
        // Free the YUV frame
//        av_free(pFrame);
        
        // Close the codec
        avcodec_close(pCodecCtx);
        
        // Close the video file
        avformat_close_input(&pFormatCtx);
    }
    else
    {
        [pool release];
        return;
    }
    
func_end:
    rtsp_conn_status = 0;
    [pool release];
}

struct frame_node
{
    void* data;
    struct frame_node* next;
};
struct av_frame_list
{
    struct frame_node* frist, *last;
    unsigned int size;
    
    int thread_running_flag;
    long frame_interval; // micro sec
    void* pFrameRGB;
    void* sws_ctx;
    int dst_w, dst_h;
} play_frame_list;
- (void)init_play_frame_list
{
    play_frame_list.size = 0;
    play_frame_list.pFrameRGB = NULL;
    play_frame_list.sws_ctx = NULL;
    
    play_frame_list.frist = NULL;
    play_frame_list.last = NULL;
    
    play_frame_list.thread_running_flag = 0;
    play_frame_list.frame_interval = 0;
    play_frame_list.dst_w = 0, play_frame_list.dst_h = 0;
}
- (void)push_back_play_frame_list: (void*)data
{
    struct frame_node* node = (struct frame_node*) malloc(sizeof(struct frame_node));
    node->data = data;
    node->next = NULL;
    
    if(play_frame_list.size == 0)
    {
        play_frame_list.frist = node;
        play_frame_list.last = node;
    }
    else
    {
        play_frame_list.last->next = node;
        play_frame_list.last = node;
    }
    
    ++play_frame_list.size;
}
- (void)local_media_play_thread
{
    static AVFrame* pFrame, *pFrameRGB;
    static struct SwsContext* sws_cxt;
    
    static struct timeval tv = {0, 0}, tv1 = {0, 0};
    play_frame_list.thread_running_flag = 1;
    while (play_frame_list.thread_running_flag)
    {
        if (play_frame_list.size == 0) {
            usleep(100);
            continue;
        }
        
        gettimeofday(&tv, NULL);
        pFrameRGB = (AVFrame*)play_frame_list.pFrameRGB;
        sws_cxt = (struct SwsContext*)play_frame_list.sws_ctx;
        pFrame = (AVFrame*)play_frame_list.frist->data;
        
        sws_scale(play_frame_list.sws_ctx, (const uint8_t* const*)pFrame->data, pFrame->linesize, 0, pFrame->height,
                  pFrameRGB->data, pFrameRGB->linesize);
        
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
        CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, pFrameRGB->data[0], play_frame_list.dst_w*play_frame_list.dst_h*3, kCFAllocatorNull);
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef cgimage = CGImageCreate(play_frame_list.dst_w, play_frame_list.dst_h, 8, 24, play_frame_list.dst_w*3, colorSpace, bitmapInfo, provider, NULL, YES, kCGRenderingIntentDefault);
        
        video_image = [[UIImage alloc] initWithCGImage:cgimage];
        [self performSelectorOnMainThread:@selector(play:) withObject:video_image waitUntilDone:YES];
        [video_image release];
        
        CGImageRelease(cgimage);
        CGColorSpaceRelease(colorSpace);
        CGDataProviderRelease(provider);
        CFRelease(data);
        
        // play_frame_list process.
        void* tmp = play_frame_list.frist;
        if(play_frame_list.size > 1)
            play_frame_list.frist = play_frame_list.frist->next;
        
        free(tmp);
        --play_frame_list.size;
        av_free(pFrame);
        
        gettimeofday(&tv1, NULL);
        long int diff = (tv1.tv_sec-tv.tv_sec)*1000000 + (tv1.tv_usec-tv.tv_usec);
        if(diff < 0 || (play_frame_list.frame_interval-diff)<0)
            usleep(play_frame_list.frame_interval);
        else
            usleep(play_frame_list.frame_interval-diff);
    }
}

- (void)rtsp_close
{
    while(rtsp_conn_status != 0)
    {
        recv_sigpipe_flag = 1;
        need_to_closed = 1;
        usleep(RTSP_CLOSE_DETECT_INTERVAL_MICSEC);
    }

    [self turn_stop];
}

- (void)play_start
{
    pause_flag = 0;
}

- (void)play_pause
{
    pause_flag = 1;
    [self turn_stop];
}

- (void)play: (UIImage*)img
{
    if (init_width == 0.0f || init_height == 0.0f) {
        CGRect rect;
        rect.origin.x = self.frame.origin.x;
        rect.origin.y = self.frame.origin.y;
        rect.size = img.size;
        
        self.frame = rect;
        init_width = rect.size.width;
        init_height = rect.size.height;
    }
    else if(init_width/init_height != img.size.width/img.size.height)
    {
        CGRect rect = {{0.0f, 0.0f}, {init_width, init_height}};
        
        CGFloat view_scale = init_width/init_height;
        CGFloat img_scale = img.size.width/img.size.height;
        if(view_scale > img_scale)
        {
            rect.size.width = rect.size.height * img_scale;
            rect.origin.x += (init_width - rect.size.width) / 2;
        }
        else
        {
            rect.size.height = rect.size.width / img_scale;
            rect.origin.y += (init_height - rect.size.height) / 2;
        }
        
        self.frame = rect;
    }
    else if(init_width/init_height == img.size.width/img.size.height)
    {
        CGRect rect = {{0.0f, 0.0f}, {init_width, init_height}};
        self.frame = rect;
    }
    
    self.image = img;
    //[self setNeedsDisplay];
}

- (int)turn_up
{
    return camera_turn_internal(sock, rtsp_addr, rtsp_addr_len, TURN_UP);
}
- (int)turn_down
{
    return camera_turn_internal(sock, rtsp_addr, rtsp_addr_len, TURN_DOWN);
}
- (int)turn_left
{
    return camera_turn_internal(sock, rtsp_addr, rtsp_addr_len, TURN_LEFT);
}
- (int)turn_right
{
    return camera_turn_internal(sock, rtsp_addr, rtsp_addr_len, TURN_RIGHT);
}
- (int)turn_loop
{
    return camera_turn_internal(sock, rtsp_addr, rtsp_addr_len, TURN_LOOP);
}
- (int)turn_stop
{
    return camera_turn_internal(sock, rtsp_addr, rtsp_addr_len, TURN_STOP);
}

static inline int camera_turn_internal(int sock, struct sockaddr_in* rtsp_addr, int rtsp_addr_len, int operation_code)
{
    int ret = -1;
    if(rtsp_addr->sin_addr.s_addr == INADDR_NONE || rtsp_addr->sin_port == 0)
        return ret;
    
    char buf[1024] = {0};
    sprintf(buf, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><PACKET><HEAD><TIMESTAMP>2010-04-20-12:58:43</TIMESTAMP><SERVICEID>0001</SERVICEID><VERSION>V01.00</VERSION><ENCRYTION>0001</ENCRYTION><ID>0101000000011111</ID><LOGINANAME>admin</LOGINANAME><PASSWORD>admin</PASSWORD></HEAD><BODY><INSTP>SETDATA</INSTP><PARAMETER>MOTOR</PARAMETER><TYPE>STRING</TYPE><DATA>X%4Xect8</DATA></BODY></PACKET>", operation_code);
    
    if( sendto(sock, (const void*)buf, strlen(buf), 0, (const struct sockaddr*)rtsp_addr, rtsp_addr_len) > 0)
        ret = 0;
    
    return ret;
}

// eg: rtsp_url = rtsp://192.168.2.200:8200/v1.3gp
static inline void init_rtsp_addr(struct sockaddr_in* addr, const char* rtsp_url)
{
    char ip_addr[32] = {0};
    const char rtsp_url_proto[] = "rtsp://";
    
    if(strcasestr(rtsp_url, rtsp_url_proto) != NULL)
    {
        const char* url_start = rtsp_url + strlen(rtsp_url_proto);
        const char* url_end = strstr(url_start, ":");
        if(url_end-url_start < sizeof(ip_addr))
            strncpy(ip_addr, url_start, url_end-url_start);
        
//        const char* port_start = url_end+1;
//        const char* port_end = strstr(port_start, "/");
//        if(port_end == NULL)
//            port_end = port_start + strlen(port_start);
//        if(port_end-port_start < sizeof(port))
//            strncpy(port, port_start, port_end-port_start);
        
        addr->sin_addr.s_addr = inet_addr(ip_addr);
        addr->sin_port = htons( CAMERA_TURN_SERVICE_PORT );
    }
    else
    {
        addr->sin_addr.s_addr = INADDR_NONE;
        addr->sin_port = 0;
    }
}

static int tcp_connect_test(struct sockaddr_in* addr, const char* rtsp_url)
{
    int conn_result = 0;
    char port[6] = {0};
    const char rtsp_url_proto[] = "rtsp://";
    int tcp_sock = -1;
    
    if(strcasestr(rtsp_url, rtsp_url_proto) != NULL)
    {
        const char* url_start = rtsp_url + strlen(rtsp_url_proto);
        const char* url_end = strstr(url_start, ":");
        
        const char* port_start = url_end+1;
        const char* port_end = strstr(port_start, "/");
        if(port_end == NULL)
             port_end = port_start + strlen(port_start);
        if(port_end-port_start < sizeof(port))
            strncpy(port, port_start, port_end-port_start);
        
        unsigned short conn_port = atoi(port);
        if(conn_port > 0)
        {
            if( (tcp_sock = socket(AF_INET, SOCK_STREAM, 0)) < 0 )
                goto conn_fail;
            
            int sock_flag = fcntl(tcp_sock, F_GETFL, 0);
            fcntl(tcp_sock, F_SETFL, sock_flag | O_NONBLOCK);
            struct timeval tv = {RTSP_CONN_TIMEOUT, 0};
            
            struct sockaddr_in test_addr = *addr;
            test_addr.sin_port = htons(conn_port);
            
            connect(tcp_sock, (const struct sockaddr*)&test_addr, sizeof(struct sockaddr_in));
            
            struct fd_set fds;
            FD_ZERO(&fds);
            FD_SET(tcp_sock, &fds);
            if( select(tcp_sock+1, NULL, &fds, NULL, &tv) > 0)
                conn_result = 1;
        }
    }
    
conn_fail:
    if(tcp_sock >= 0)
        close(tcp_sock);
    
    return conn_result;
}

@end
