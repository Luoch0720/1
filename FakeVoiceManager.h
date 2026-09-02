#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FakeVoiceManager : NSObject

/// 单例
+ (instancetype)shared;

/// 待发送的假语音文件路径（已复制到沙盒 tmp）
@property (nonatomic, copy, nullable) NSString *pendingFakeVoicePath;

/// 假语音时长（秒）
@property (nonatomic, assign) NSTimeInterval pendingDuration;

/// 是否有待发送的假语音
@property (nonatomic, readonly) BOOL hasPendingFakeVoice;

/// 启动：添加悬浮按钮
- (void)install;

/// 清除待发送状态
- (void)clearPending;

/// 从录音器实例中替换录音文件为假语音文件
/// 返回 YES 表示替换成功
- (BOOL)swapRecordingFileForRecorder:(id)recorder;

/// 验证文件是否为 Ogg Opus 格式
+ (BOOL)isOggOpusFile:(NSString *)path;

/// 获取音频时长（秒），失败返回 0
+ (NSTimeInterval)audioDurationForFile:(NSString *)path;

/// 日志
void FVLog(NSString *format, ...);

NS_ASSUME_NONNULL_END
