//
//  SampleHandler.m
//  ScreenCapture
//
//  Created by minzhe on 2019/7/31.
//  Copyright © 2019 minzhe. All rights reserved.
//


#import "SampleHandler.h"
#import <LFLiveKit/LFLiveKit.h>
#import "XDXAduioEncoder.h"
#import <UserNotifications/UserNotifications.h>
#import "MixAudioManager.h"

#import <sys/sysctl.h>
#import <mach/mach.h>

//输出音频的采样率(也是session设置的采样率)，
const double kGraphSampleRate = 44100.0;
//每次回调提供多长时间的数据,结合采样率 0.005 = x*1/44100, x = 220.5, 因为回调函数中的inNumberFrames是2的幂，所以x应该是256
const double kSessionBufDuration    = 0.005;

@interface SampleHandler () <LFStreamSocketDelegate, LFVideoEncodingDelegate, LFAudioEncodingDelegate, MixAudioManagerDelegate>

@property (nonatomic, strong) NSUserDefaults *userDefaults;

@property (nonatomic, strong) id<LFStreamSocket> socket;
@property (nonatomic, strong) LFLiveStreamInfo *streamInfo;

@property (nonatomic, strong) id<LFVideoEncoding> videoEncoder;
/// 音频编码
@property (nonatomic, strong) id<LFAudioEncoding> audioEncoder;

@property (nonatomic, strong) XDXAduioEncoder *audioEncoder2;


@property (nonatomic, strong) MixAudioManager *mixAudioManager;

/// 音频配置
@property (nonatomic, strong) LFLiveAudioConfiguration *audioConfiguration;
/// 视频配置
@property (nonatomic, strong) LFLiveVideoConfiguration *videoConfiguration;



@property (nonatomic, strong) dispatch_semaphore_t lock;
@property (nonatomic, assign) uint64_t relativeTimestamps;

@property (nonatomic, assign) BOOL canUpload;

@property (nonatomic, strong) dispatch_queue_t rotateQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;

@property (nonatomic, strong) CIContext *ciContext;

@property (nonatomic, strong) LFVideoFrame *lastRecordFrame;
@property (nonatomic, assign) uint64_t lastTimeSpace;
@property (nonatomic, strong) CIImage *lastCIImage;
@property (nonatomic, assign) size_t lastWidth;
@property (nonatomic, assign) size_t lastHeight;
@property (nonatomic, assign) uint64_t lastTime;

@property (nonatomic, assign) size_t videoWidth;
@property (nonatomic, assign) size_t videoHeight;

@property (nonatomic, assign) UIInterfaceOrientation encoderOrientation;
@property (nonatomic, assign) CGImagePropertyOrientation rotateOrientation;

@property (nonatomic, assign) CMSampleBufferRef applicationBuffer;
@property (nonatomic, assign) CMSampleBufferRef micBuffer;

/// 音视频是否对齐
@property (nonatomic, assign) BOOL AVAlignment;
/// 当前是否采集到了音频
@property (nonatomic, assign) BOOL hasCaptureAudio;
/// 当前是否采集到了关键帧
@property (nonatomic, assign) BOOL hasKeyFrameVideo;

@end

@implementation SampleHandler

- (MixAudioManager *)mixAudioManager {
    if (!_mixAudioManager) {
        _mixAudioManager = [[MixAudioManager alloc] init];
        _mixAudioManager.delegate = self;
    }
    return _mixAudioManager;
}

- (LFLiveStreamInfo *)streamInfo {
    if (!_streamInfo) {
        _streamInfo = [[LFLiveStreamInfo alloc] init];
        _streamInfo.url = [_userDefaults objectForKey:@"urlStr"];
    }
    
    return _streamInfo;
}

- (id<LFStreamSocket>)socket {
    if (!_socket) {
        _socket = [[LFStreamRTMPSocket alloc] initWithStream:self.streamInfo reconnectInterval:0 reconnectCount:0];
        [_socket setDelegate:self];
    }
    return _socket;
}

- (id<LFVideoEncoding>)videoEncoder {
    if (!_videoEncoder) {
        _videoEncoder = [[LFHardwareVideoEncoder alloc] initWithVideoStreamConfiguration:self.videoConfiguration];
        [_videoEncoder setDelegate:self];
        NSLog(@"self.videoConfiguration d方向：%ld", (long)self.videoConfiguration.outputImageOrientation);
    }
    return _videoEncoder;
}

- (LFLiveVideoConfiguration *)videoConfiguration {
    if (!_videoConfiguration) {
        _videoConfiguration = [LFLiveVideoConfiguration defaultConfigurationForQuality:LFLiveVideoQuality_High3 outputImageOrientation:self.encoderOrientation width:self.videoWidth height:self.videoHeight];
//        _videoConfiguration = [LFLiveVideoConfiguration defaultConfigurationForQuality:LFLiveVideoQuality_High3 outputImageOrientation:self.encoderOrientation];

    }
    return _videoConfiguration;

}

- (id<LFAudioEncoding>)audioEncoder {
    if (!_audioEncoder) {
        _audioEncoder = [[LFHardwareAudioEncoder alloc] initWithAudioStreamConfiguration:self.audioConfiguration];
        [_audioEncoder setDelegate:self];
    }
    return _audioEncoder;
}

- (LFLiveAudioConfiguration *)audioConfiguration {
    if (!_audioConfiguration) {
        _audioConfiguration = [LFLiveAudioConfiguration defaultConfiguration];
    }
    return _audioConfiguration;
}

- (UIInterfaceOrientation)encoderOrientation {
    NSInteger screenOrientationValue = [[_userDefaults objectForKey:@"screenOrientationValue"] integerValue];
    UIInterfaceOrientation orientationValue = UIInterfaceOrientationPortrait;
    switch (screenOrientationValue) {
        case 1:
            orientationValue = UIInterfaceOrientationLandscapeLeft;
            break;
        case 2:
            orientationValue = UIInterfaceOrientationLandscapeRight;
            break;
        default:
            break;
    }
    return orientationValue;
}

- (CGImagePropertyOrientation)rotateOrientation {
    NSInteger screenOrientationValue = [[_userDefaults objectForKey:@"screenOrientationValue"] integerValue];
    CGImagePropertyOrientation rotateOrientation = kCGImagePropertyOrientationUp;
    switch (screenOrientationValue) {
        case 1:
            rotateOrientation = kCGImagePropertyOrientationLeft;
            break;
        case 2:
            rotateOrientation = kCGImagePropertyOrientationRight;
            break;
        default:
            break;
    }
    return rotateOrientation;
}


- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *,NSObject *> *)setupInfo {
    _videoConfiguration = nil;
    _videoEncoder = nil;
    _streamInfo = nil;
    
    if (_socket) {
        [_socket stop];
        _socket = nil;
    }
    
    self.userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.gunmm.CaptureDeviceProject"];
    self.rotateQueue = dispatch_queue_create("rotateQueue", nil);
    self.audioQueue = dispatch_queue_create("audioQueue", nil);

    [self.socket start];
    _ciContext = [CIContext contextWithOptions:nil];
    
    __weak typeof(self) weakSelf = self;
    CADisplayLink *_link = [CADisplayLink displayLinkWithTarget:weakSelf selector:@selector(checkFPS:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
//    [self mixer];
}

- (void)sendLocalNotificationToHostAppWithTitle:(NSString*)title msg:(NSString*)msg userInfo:(NSDictionary*)userInfo
{
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString localizedUserNotificationStringForKey:title arguments:nil];
    content.body = [NSString localizedUserNotificationStringForKey:msg  arguments:nil];
    content.sound = [UNNotificationSound defaultSound];
    content.userInfo = userInfo;
    
    // 在设定时间后推送本地推送
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger
                                                  triggerWithTimeInterval:0.1f repeats:NO];
    
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"gunmm.CaptureDeviceProject"
                                                                          content:content trigger:trigger];
    //添加推送成功后的处理！
    [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
    }];
}

- (void)checkFPS:(CADisplayLink *)link {
    if (!self.canUpload) {
        return;
    }
    if (_lastTime == 0) {
        _lastTime = link.timestamp;
        return;
    }

    NSTimeInterval delta = link.timestamp - _lastTime;
    if (delta < 2) return;
    _lastTime = link.timestamp;
    if (_lastTimeSpace == 0) {
        _lastTimeSpace = _lastRecordFrame.timestamp;
        return;
    }
    if (_lastTimeSpace == _lastRecordFrame.timestamp) {
        __weak typeof(self) wSelf = self;
        dispatch_async(wSelf.rotateQueue, ^{
            [wSelf dealWithLastCIImage:wSelf.lastCIImage];
        });
        NSLog(@"*****************************");
    }
    _lastTimeSpace = _lastRecordFrame.timestamp;
}

- (void)broadcastPaused {
    // User has requested to pause the broadcast. Samples will stop being delivered.
    [self sendLocalNotificationToHostAppWithTitle:@"屏幕推流" msg:@"录屏暂停" userInfo:nil];
    NSLog(@"------Paused-------");
}

- (void)broadcastResumed {
    // User has requested to resume the broadcast. Samples delivery will resume.
    [self sendLocalNotificationToHostAppWithTitle:@"屏幕推流" msg:@"录屏重新开始" userInfo:nil];
    NSLog(@"------Resumed-------");
}

- (void)broadcastFinished {
    // User has requested to finish the broadcast.
    [self sendLocalNotificationToHostAppWithTitle:@"屏幕推流" msg:@"录屏已结束" userInfo:nil];
    NSLog(@"------Finished-------");
}


- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {
    if ([self usedMemory] > 45) {
        return;
    }
    switch (sampleBufferType) {
        case RPSampleBufferTypeVideo:
        {
            if (self.canUpload) {
                __weak typeof(self) weakSelf = self;
                CFRetain(sampleBuffer);
                dispatch_async(weakSelf.rotateQueue, ^{
                    [weakSelf dealWithSampleBuffer:sampleBuffer];
                    CFRelease(sampleBuffer);
                });
            }
        }
            break;
        case RPSampleBufferTypeAudioApp:
            if (self.canUpload) {
                CFRetain(sampleBuffer);
                //                __weak typeof(self) weakSelf = self;

                dispatch_async(self.audioQueue, ^{
                    //从samplebuffer中获取blockbuffer
                    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
                    size_t pcmLength = 0;
                    char *pcmData = NULL;
                    //获取blockbuffer中的pcm数据的指针和长度
                    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &pcmLength, &pcmData);
                    if (status != noErr) {
                        NSLog(@"从block中获取pcm数据失败");
                        CFRelease(sampleBuffer);
                        return;
                    } else {
                        CMAudioFormatDescriptionRef audioFormatDes =  (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
//                        //获取输入的asbd的信息
                        AudioStreamBasicDescription inAudioStreamBasicDescription = *(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDes));
                        inAudioStreamBasicDescription.mFormatFlags = 0xe;
                        [self.audioEncoder setCustomInputFormat:inAudioStreamBasicDescription];
                        [self.mixAudioManager sendAppBufferList:[[NSData alloc] initWithBytes:pcmData length:pcmLength] timeStamp:(CACurrentMediaTime()*1000)];
//                        //在堆区分配内存用来保存编码后的aac数据
//                        NSData *data = [[NSData alloc] initWithBytes:pcmData length:pcmLength];
//                        [self.audioEncoder encodeAudioData:data timeStamp:(CACurrentMediaTime()*1000)];
                    }
                    CFRelease(sampleBuffer);
                });
            }
            break;
        case RPSampleBufferTypeAudioMic:
        {
            if (self.canUpload) {
                CFRetain(sampleBuffer);
                __weak typeof(self) weakSelf = self;

                dispatch_async(self.audioQueue, ^{
                    //从samplebuffer中获取blockbuffer
                    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
                    size_t pcmLength = 0;
                    char *pcmData = NULL;
                    //获取blockbuffer中的pcm数据的指针和长度
                    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &pcmLength, &pcmData);
                    if (status != noErr) {
                        NSLog(@"从block中获取pcm数据失败");
                        CFRelease(sampleBuffer);
                        return;
                    } else {
                        
                        
                        
                        CMAudioFormatDescriptionRef audioFormatDes =  (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(sampleBuffer);
                        //获取输入的asbd的信息
                        AudioStreamBasicDescription inAudioStreamBasicDescription = *(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDes));
                        
                        inAudioStreamBasicDescription.mFormatFlags = 0xe;
                        [self.audioEncoder setCustomInputFormat:inAudioStreamBasicDescription];
//                        [self.mixAudioManager sendMicBufferList:[[NSData alloc] initWithBytes:pcmData length:pcmLength] timeStamp:(CACurrentMediaTime()*1000)];
                        
                        if (!self.audioEncoder2) {
                            AudioStreamBasicDescription inputFormat = {0};
                            inputFormat.mSampleRate = 44100;
                            inputFormat.mFormatID = kAudioFormatLinearPCM;
                            inputFormat.mFormatFlags = inAudioStreamBasicDescription.mFormatFlags;
                            inputFormat.mChannelsPerFrame = 1;
                            inputFormat.mFramesPerPacket = 1;
                            inputFormat.mBitsPerChannel = 16;
                            inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame;
                            inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket;
                            self.audioEncoder2 = [[XDXAduioEncoder alloc] initWithSourceFormat:inputFormat
                                                                                  destFormatID:kAudioFormatMPEG4AAC
                                                                                    sampleRate:44100
                                                                           isUseHardwareEncode:YES];
                        }
                        ///<  发送
                        AudioBuffer inBuffer;
                        inBuffer.mNumberChannels = 1;
                        inBuffer.mData = pcmData;
                        inBuffer.mDataByteSize = (UInt32)pcmLength;

                        AudioBufferList buffers;
                        buffers.mNumberBuffers = 1;
                        buffers.mBuffers[0] = inBuffer;

                        
                        Float64 currentTime = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(CACurrentMediaTime()));

                        int64_t pts = (int64_t)((currentTime - 100) * 1000);
                        [self.audioEncoder2 encodeAudioWithSourceBuffer:buffers.mBuffers[0].mData sourceBufferSize:buffers.mBuffers[0].mDataByteSize pts:pts completeHandler:^(LFAudioFrame * _Nonnull frame) {
                            [weakSelf.mixAudioManager sendMicBufferList:frame.data timeStamp:(CACurrentMediaTime()*1000)];
                        }];
                       
//                        //在堆区分配内存用来保存编码后的aac数据
//
//                        NSData *data = [[NSData alloc] initWithBytes:pcmData length:pcmLength];
//                        [self.audioEncoder encodeAudioData:data timeStamp:(CACurrentMediaTime()*1000)];
                    }
                    CFRelease(sampleBuffer);
                });
            }
            break;
        }
            
        default:
            break;
    }
}

- (uint64_t)uploadTimestamp:(uint64_t)captureTimestamp{
    dispatch_semaphore_wait(self.lock, DISPATCH_TIME_FOREVER);
    uint64_t currentts = 0;
    currentts = captureTimestamp - self.relativeTimestamps;
    dispatch_semaphore_signal(self.lock);
    return currentts;
}

- (dispatch_semaphore_t)lock{
    if(!_lock){
        _lock = dispatch_semaphore_create(1);
    }
    return _lock;
}

- (void)videoEncoder:(nullable id<LFVideoEncoding>)encoder videoFrame:(nullable LFVideoFrame *)frame {
    if (self.canUpload) {
        if(frame.isKeyFrame) self.hasKeyFrameVideo = YES;
        if(self.AVAlignment) {
            [self pushSendBuffer:frame];
            self.lastRecordFrame = frame;
        }
    }
}

- (void)audioEncoder:(nullable id<LFAudioEncoding>)encoder audioFrame:(nullable LFAudioFrame *)frame {
    if (self.canUpload){
        if (self.hasKeyFrameVideo == YES) {
            self.hasCaptureAudio = YES;
        }
        if(self.AVAlignment){
            [self pushSendBuffer:frame];
        }
    }
}

#pragma mark -- PrivateMethod
- (void)pushSendBuffer:(LFFrame*)frame{
    if(self.relativeTimestamps == 0){
        self.relativeTimestamps = frame.timestamp;
    }
    frame.timestamp = [self uploadTimestamp:frame.timestamp];
    [self.socket sendFrame:frame];
}

#pragma mark -- LFStreamTcpSocketDelegate
- (void)socketStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveState)status {
    NSLog(@"--------%lu", status);
    
    if (status == LFLiveStart) {
        if (!self.canUpload) {
            self.AVAlignment = NO;
            self.hasCaptureAudio = NO;
            self.hasKeyFrameVideo = NO;
            self.relativeTimestamps = 0;
            self.canUpload = YES;
        }
    } else if(status == LFLiveStop || status == LFLiveError){
        self.canUpload = NO;
        [self sendLocalNotificationToHostAppWithTitle:@"屏幕推流" msg:@"连接错误，推流已停止" userInfo:nil];
    }

    
}

- (void)socketDidError:(nullable id<LFStreamSocket>)socket errorCode:(LFLiveSocketErrorCode)errorCode {
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:errorCode:)]) {
    //            [self.delegate liveSession:self errorCode:errorCode];
    //        }
    //    });
//    NSLog(@"errorCode == %lu", (unsigned long)errorCode);

}

- (void)socketDebug:(nullable id<LFStreamSocket>)socket debugInfo:(nullable LFLiveDebug *)debugInfo {
//    NSLog(@"debugInfo == %@", debugInfo);
    //    self.debugInfo = debugInfo;
    //    if (self.showDebugInfo) {
    //        dispatch_async(dispatch_get_main_queue(), ^{
    //            if (self.delegate && [self.delegate respondsToSelector:@selector(liveSession:debugInfo:)]) {
    //                [self.delegate liveSession:self debugInfo:debugInfo];
    //            }
    //        });
    //    }
}

- (void)socketBufferStatus:(nullable id<LFStreamSocket>)socket status:(LFLiveBuffferState)status {
    if (self.canUpload) {
        NSLog(@"LFLiveBuffferState---  %ld", status);
        NSUInteger videoBitRate = [self.videoEncoder videoBitRate];
        if (status == LFLiveBuffferDecline) {
            if (videoBitRate < _videoConfiguration.videoMaxBitRate) {
                videoBitRate = videoBitRate + 50 * 1000;
                [self.videoEncoder setVideoBitRate:videoBitRate];
                NSLog(@"Increase bitrate %@", @(videoBitRate));
            }
        } else {
            if (videoBitRate > self.videoConfiguration.videoMinBitRate) {
                videoBitRate = videoBitRate - 100 * 1000;
                [self.videoEncoder setVideoBitRate:videoBitRate];
                NSLog(@"Decline bitrate %@", @(videoBitRate));
            }
        }
    }
}

- (void)dealWithSampleBuffer:(CMSampleBufferRef)buffer {
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(buffer);
    CIImage *ciimage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    self.lastCIImage = ciimage;
    
    CGFloat widthScale = width/720.0;
    CGFloat heightScale = height/1280.0;
    CGFloat realWidthScale = 1;
    CGFloat realHeightScale = 1;
    
    if (widthScale > 1 || heightScale > 1) {
        if (widthScale < heightScale) {
            realHeightScale = 1280.0/height;
            CGFloat nowWidth = width * 1280 / height;
            height = 1280;
            realWidthScale = nowWidth/width;
            width = nowWidth;
        } else {
            realWidthScale = 720.0/width;
            CGFloat nowHeight = 720 * height / width;
            width = 720;
            realHeightScale = nowHeight/height;
            height = nowHeight;
        }
    }
    self.videoWidth = width;
    self.videoHeight = height;
    
    if (self.rotateOrientation == kCGImagePropertyOrientationUp) {
        if (realWidthScale == 1 && realHeightScale == 1) {
            [self.videoEncoder encodeVideoData:pixelBuffer timeStamp:(CACurrentMediaTime()*1000)];
        } else {
            CIImage *newImage = [ciimage imageByApplyingTransform:CGAffineTransformMakeScale(realWidthScale, realHeightScale)];
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRef newPixcelBuffer = nil;
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &newPixcelBuffer);
            [_ciContext render:newImage toCVPixelBuffer:newPixcelBuffer];
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            [self.videoEncoder encodeVideoData:newPixcelBuffer timeStamp:(CACurrentMediaTime()*1000)];
            CVPixelBufferRelease(newPixcelBuffer);
        }
    } else {
        // 旋转的方法
        CIImage *wImage = [ciimage imageByApplyingCGOrientation:self.rotateOrientation];
        
        CIImage *newImage = [wImage imageByApplyingTransform:CGAffineTransformMakeScale(realWidthScale, realHeightScale)];
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRef newPixcelBuffer = nil;
        CVPixelBufferCreate(kCFAllocatorDefault, height, width, kCVPixelFormatType_32BGRA, nil, &newPixcelBuffer);
        [_ciContext render:newImage toCVPixelBuffer:newPixcelBuffer];
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        [self.videoEncoder encodeVideoData:newPixcelBuffer timeStamp:(CACurrentMediaTime()*1000)];
        CVPixelBufferRelease(newPixcelBuffer);
    }
    self.lastWidth = width;
    self.lastHeight = height;
    
}

- (void)dealWithLastCIImage:(CIImage *)lastCIImage {
    // 旋转的方法
    NSLog(@"------------------补帧方法---------------------");
    CIImage *wImage;
    size_t width, height;
    if (self.rotateOrientation != kCGImagePropertyOrientationUp) {
        wImage = [lastCIImage imageByApplyingCGOrientation:self.rotateOrientation];
        width = self.lastHeight;
        height = self.lastWidth;
    } else {
        wImage = lastCIImage;
        width = self.lastWidth;
        height = self.lastHeight;
    }
    CIImage *newImage = [wImage imageByApplyingTransform:CGAffineTransformMakeScale(1, 1)];
    CVPixelBufferRef newPixcelBuffer = nil;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &newPixcelBuffer);
    [_ciContext render:newImage toCVPixelBuffer:newPixcelBuffer];
    [self.videoEncoder encodeVideoData:newPixcelBuffer timeStamp:(CACurrentMediaTime()*1000)];
    CVPixelBufferRelease(newPixcelBuffer);
}

- (BOOL)AVAlignment{
    if(self.hasCaptureAudio && self.hasKeyFrameVideo) return YES;
    else  return NO;
}

- (double)usedMemory
{
    task_basic_info_data_t taskInfo;
    mach_msg_type_number_t infoCount = TASK_BASIC_INFO_COUNT;
    kern_return_t kernReturn = task_info(mach_task_self(),
                                         TASK_BASIC_INFO,
                                         (task_info_t)&taskInfo,
                                         &infoCount);
    if (kernReturn != KERN_SUCCESS) {
        return NSNotFound;
    }
    return taskInfo.resident_size / 1024.0 / 1024.0;
}
- (void)mixDidOutputModel:(MixAudioModel *)mixAudioModel {
    
    
     [self.audioEncoder encodeAudioData:mixAudioModel.videoData timeStamp:(CACurrentMediaTime()*1000)];
//    Float64 currentTime = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(CACurrentMediaTime()));
//    int64_t pts = (int64_t)((currentTime - 100) * 1000);
//    [self.audioEncoder2 encodeAudioWithSourceBuffer:mixAudioModel.buffer.mData sourceBufferSize:mixAudioModel.buffer.mDataByteSize pts:pts completeHandler:^(LFAudioFrame * _Nonnull frame) {
//        frame.timestamp = mixAudioModel.timeStamp;
//        if (self.canUpload) {
//            if (self.hasKeyFrameVideo) {
//                self.hasCaptureAudio = YES;
//            }
//            if(self.AVAlignment){
//                if(self.relativeTimestamps == 0){
//                    self.relativeTimestamps = frame.timestamp;
//                }
//                frame.timestamp = [self uploadTimestamp:frame.timestamp];
//                char exeData[2];
//                exeData[0] = self.audioConfiguration.asc[0];
//                exeData[1] = self.audioConfiguration.asc[1];
//                frame.audioInfo = [NSData dataWithBytes:exeData length:2];
//                [self.socket sendFrame:frame];
//            }
//        }
//    }];
}

@end
