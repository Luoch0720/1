#import "FakeVoiceManager.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// ============================================================================
// 日志
// ============================================================================
void FVLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[FakeVoice] %@", msg);
}

// ============================================================================
// 悬浮按钮
// ============================================================================
@interface FakeVoiceFloatButton : UIButton
@property (nonatomic, weak) UIView *hostView;
@property (nonatomic, assign) CGPoint startPoint;
@end

@implementation FakeVoiceFloatButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithRed:0.0 green:0.53 blue:1.0 alpha:0.9];
        self.layer.cornerRadius = 22;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 6;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        [self setTitle:@"🎤" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:20];
    }
    return self;
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.superview;
    if (!superview) return;
    
    CGPoint translation = [pan translationInView:superview];
    
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.startPoint = self.center;
    }
    
    CGPoint newCenter = CGPointMake(self.startPoint.x + translation.x,
                                     self.startPoint.y + translation.y);
    // 限制在屏幕内
    CGFloat margin = 30;
    newCenter.x = MAX(margin, MIN(superview.bounds.size.width - margin, newCenter.x));
    newCenter.y = MAX(margin + 40, MIN(superview.bounds.size.height - margin, newCenter.y));
    self.center = newCenter;
}

@end

// ============================================================================
// FakeVoiceManager 实现
// ============================================================================
@interface FakeVoiceManager () <UIDocumentPickerDelegate>
@property (nonatomic, strong) FakeVoiceFloatButton *floatButton;
@property (nonatomic, weak) UIWindow *observedWindow;
@property (nonatomic, copy) NSString *tempVoicePath;
@end

@implementation FakeVoiceManager

+ (instancetype)shared {
    static FakeVoiceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FakeVoiceManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _pendingFakeVoicePath = nil;
        _pendingDuration = 0;
    }
    return self;
}

- (BOOL)hasPendingFakeVoice {
    return self.pendingFakeVoicePath != nil;
}

// ============================================================================
// 安装悬浮按钮
// ============================================================================
- (void)install {
    FVLog(@"install called");
    
    // 监听 keyWindow 变化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidBecomeKey:)
                                                 name:UIWindowDidBecomeKeyNotification
                                               object:nil];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self ensureFloatButton];
    });
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self ensureFloatButton];
    });
}

- (void)ensureFloatButton {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    if (!keyWindow) return;
    
    if (self.floatButton && self.floatButton.superview == keyWindow) return;
    
    [self.floatButton removeFromSuperview];
    
    self.floatButton = [[FakeVoiceFloatButton alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
    self.floatButton.center = CGPointMake(keyWindow.bounds.size.width - 35,
                                           keyWindow.bounds.size.height - 120);
    [self.floatButton addTarget:self
                         action:@selector(floatButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [keyWindow addSubview:self.floatButton];
    
    FVLog(@"float button added to window");
}

// ============================================================================
// 点击悬浮按钮 → 弹出文件选择器
// ============================================================================
- (void)floatButtonTapped {
    FVLog(@"float button tapped");
    
    UIViewController *topVC = [self topViewController];
    if (!topVC) {
        FVLog(@"no top view controller");
        return;
    }
    
    // 如果有待发送的假语音，先清除
    if (self.hasPendingFakeVoice) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"假语音"
            message:[NSString stringWithFormat:@"已选文件待发送：\n%@\n时长：%.1f秒\n\n去聊天界面按麦克风随便录一句然后发送，实际发出的是这个文件。",
                     [self.pendingFakeVoicePath lastPathComponent],
                     self.pendingDuration]
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"清除重选" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self clearPending];
            [self presentFilePickerFrom:topVC];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"保持" style:UIAlertActionStyleCancel handler:nil]];
        [topVC presentViewController:ac animated:YES completion:nil];
        return;
    }
    
    [self presentFilePickerFrom:topVC];
}

- (void)presentFilePickerFrom:(UIViewController *)vc {
    UIDocumentPickerViewController *picker = nil;
    
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc]
                  initForOpeningContentTypes:@[UTType.audio]
                  asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:@[@"public.audio"]
                  inMode:UIDocumentPickerModeImport];
    }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [vc presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    
    NSURL *url = urls.firstObject;
    FVLog(@"picked file: %@", url.path);
    
    // 安全范围资源
    BOOL accessing = [url startAccessingSecurityScopedResource];
    
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    
    if (accessing) [url stopAccessingSecurityScopedResource];
    
    if (!data || error) {
        FVLog(@"failed to read file: %@", error);
        [self showAlert:@"读取失败" message:error.localizedDescription ?: @"无法读取文件"];
        return;
    }
    
    // 保存到 tmp 目录
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *ext = url.pathExtension.length ? url.pathExtension : @"ogg";
    NSString *tmpPath = [tmpDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"fake_voice_%@.%@", uuid, ext]];
    
    if (![data writeToFile:tmpPath options:NSDataWritingAtomic error:&error]) {
        FVLog(@"failed to save temp file: %@", error);
        [self showAlert:@"保存失败" message:error.localizedDescription];
        return;
    }
    
    // 验证 Ogg 格式
    if (![FakeVoiceManager isOggOpusFile:tmpPath]) {
        FVLog(@"file is not Ogg Opus, ext=%@", ext);
        // 不强制拒绝，提示用户
        [self showAlert:@"格式提示"
                message:@"选中的文件可能不是 Ogg Opus 格式。Telegram 语音消息需要 Ogg Opus（单声道 48kHz）。是否继续？"
              confirm:^{
            [self setPendingVoice:tmpPath];
        }];
        return;
    }
    
    [self setPendingVoice:tmpPath];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    FVLog(@"picker cancelled");
}

- (void)setPendingVoice:(NSString *)path {
    self.pendingFakeVoicePath = path;
    self.pendingDuration = [FakeVoiceManager audioDurationForFile:path];
    
    FVLog(@"pending fake voice set: %@ (%.1fs)", path, self.pendingDuration);
    
    [self showAlert:@"假语音已就绪"
            message:[NSString stringWithFormat:
                     @"文件：%@\n时长：%.1f 秒\n\n现在去聊天界面，按麦克风按钮随便录一句（哪怕静音），然后点发送。实际发出的是这个文件。",
                     [path lastPathComponent], self.pendingDuration]];
}

// ============================================================================
// 替换录音文件 —— 核心
// ============================================================================
- (BOOL)swapRecordingFileForRecorder:(id)recorder {
    if (!self.hasPendingFakeVoice) {
        FVLog(@"no pending fake voice, skip swap");
        return NO;
    }
    
    FVLog(@"attempting to swap recording file for recorder: %@", [recorder class]);
    
    NSString *recordingPath = nil;
    
    // 方式1：KVC 尝试常见属性名
    NSArray *keyCandidates = @[@"recordingURL", @"_recordingURL",
                               @"recordingPath", @"_recordingPath",
                               @"outputURL", @"_outputURL",
                               @"outputPath", @"_outputPath",
                               @"fileURL", @"_fileURL",
                               @"filePath", @"_filePath",
                               @"tempURL", @"_tempURL",
                               @"url", @"_url"];
    
    for (NSString *key in keyCandidates) {
        @try {
            id value = [recorder valueForKey:key];
            if ([value isKindOfClass:[NSURL class]]) {
                recordingPath = [(NSURL *)value path];
                FVLog(@"found recording path via KVC key '%@': %@", key, recordingPath);
                break;
            } else if ([value isKindOfClass:[NSString class]]) {
                recordingPath = (NSString *)value;
                FVLog(@"found recording path via KVC key '%@': %@", key, recordingPath);
                break;
            }
        } @catch (NSException *e) {
            // 忽略，试下一个
        }
    }
    
    // 方式2：直接扫 ivar
    if (!recordingPath) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([recorder class], &count);
        if (ivars) {
            for (unsigned int i = 0; i < count; i++) {
                const char *name = ivar_getName(ivars[i]);
                if (!name) continue;
                NSString *ivarName = [NSString stringWithUTF8String:name];
                if ([ivarName containsString:@"URL"] || [ivarName containsString:@"Path"] ||
                    [ivarName containsString:@"File"] || [ivarName containsString:@"url"] ||
                    [ivarName containsString:@"path"] || [ivarName containsString:@"file"]) {
                    @try {
                        id value = object_getIvar(recorder, ivars[i]);
                        if ([value isKindOfClass:[NSURL class]]) {
                            recordingPath = [(NSURL *)value path];
                            FVLog(@"found recording path via ivar '%@': %@", ivarName, recordingPath);
                            break;
                        } else if ([value isKindOfClass:[NSString class]]) {
                            recordingPath = (NSString *)value;
                            FVLog(@"found recording path via ivar '%@': %@", ivarName, recordingPath);
                            break;
                        }
                    } @catch (NSException *e) {}
                }
            }
            free(ivars);
        }
    }
    
    // 方式3：在 tmp 目录找最新的 .ogg 文件
    if (!recordingPath) {
        FVLog(@"could not find recording path via KVC/ivar, scanning tmp dir");
        NSString *tmpDir = NSTemporaryDirectory();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *files = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
        NSString *newestOgg = nil;
        NSDate *newestDate = nil;
        for (NSString *f in files) {
            if ([[f pathExtension] caseInsensitiveCompare:@"ogg"] == NSOrderedSame ||
                [[f pathExtension] caseInsensitiveCompare:@"opus"] == NSOrderedSame) {
                NSString *fullPath = [tmpDir stringByAppendingPathComponent:f];
                NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                NSDate *modDate = attrs[NSFileModificationDate];
                if (!newestDate || [modDate compare:newestDate] == NSOrderedDescending) {
                    newestDate = modDate;
                    newestOgg = fullPath;
                }
            }
        }
        if (newestOgg) {
            recordingPath = newestOgg;
            FVLog(@"found newest ogg in tmp: %@", recordingPath);
        }
    }
    
    if (!recordingPath) {
        FVLog(@"ERROR: could not locate recording file path");
        return NO;
    }
    
    // 执行替换
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    
    // 先删原文件
    if ([fm fileExistsAtPath:recordingPath]) {
        [fm removeItemAtPath:recordingPath error:&error];
        if (error) {
            FVLog(@"failed to remove original: %@", error);
        }
    }
    
    // 复制假语音文件
    BOOL copied = [fm copyItemAtPath:self.pendingFakeVoicePath
                              toPath:recordingPath
                               error:&error];
    
    if (!copied) {
        FVLog(@"failed to copy fake voice: %@", error);
        return NO;
    }
    
    FVLog(@"SUCCESS: replaced recording file with fake voice");
    
    // 尝试替换 duration 属性
    [self trySetDuration:self.pendingDuration onRecorder:recorder];
    
    return YES;
}

- (void)trySetDuration:(NSTimeInterval)duration onRecorder:(id)recorder {
    NSArray *durationKeys = @[@"duration", @"_duration",
                              @"recordingDuration", @"_recordingDuration",
                              @"audioDuration", @"_audioDuration",
                              @"length", @"_length"];
    for (NSString *key in durationKeys) {
        @try {
            [recorder setValue:@(duration) forKey:key];
            FVLog(@"set duration via key '%@'", key);
            return;
        } @catch (NSException *e) {}
    }
    FVLog(@"could not set duration property");
}

// ============================================================================
// 清除待发送
// ============================================================================
- (void)clearPending {
    if (self.pendingFakeVoicePath) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:self.pendingFakeVoicePath error:nil];
    }
    self.pendingFakeVoicePath = nil;
    self.pendingDuration = 0;
    FVLog(@"pending cleared");
}

// ============================================================================
// 工具方法
// ============================================================================

+ (BOOL)isOggOpusFile:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    @try {
        NSData *header = [fh readDataOfLength:4];
        [fh closeFile];
        if (header.length < 4) return NO;
        const unsigned char *bytes = header.bytes;
        // OggS 魔数
        return bytes[0] == 'O' && bytes[1] == 'g' && bytes[2] == 'g' && bytes[3] == 'S';
    } @catch (NSException *e) {
        return NO;
    }
}

+ (NSTimeInterval)audioDurationForFile:(NSString *)path {
    @try {
        NSURL *url = [NSURL fileURLWithPath:path];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        CMTime duration = asset.duration;
        if (CMTIME_IS_VALID(duration) && duration.timescale > 0) {
            return (NSTimeInterval)duration.value / duration.timescale;
        }
    } @catch (NSException *e) {}
    return 0;
}

- (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
    
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    [self showAlert:title message:message confirm:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message confirm:(void (^_Nullable)(void))confirm {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = [self topViewController];
        if (!vc) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
        if (confirm) {
            [ac addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                confirm();
            }]];
            [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        } else {
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        }
        [vc presentViewController:ac animated:YES completion:nil];
    });
}

@end
