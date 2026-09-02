// TelegramVoiceNoteTweak — 主入口
// 功能：在 Telegram iOS 中把本地 Ogg Opus 文件作为语音消息发送
//
// 原理：
//   1. 悬浮按钮选本地音频文件 → 存为待发送
//   2. Hook ManagedAudioRecorderImpl 的 stopRecordingWithCompletion:
//      录音停止后，把录音文件替换成我们选的文件
//   3. 用户正常点发送，Telegram 上传并发送替换后的文件
//
// 适用：Telegram 12.9.x（其他版本需验证类名/方法名）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FakeVoiceManager.h"

// ============================================================================
// 通用 hook 工具
// ============================================================================

///  hook 一个实例方法，保存原 IMP
///  返回 YES 表示成功
static BOOL hookInstanceMethod(NSString *className,
                               NSString *selectorName,
                               IMP newImp,
                               IMP *_Nullable origImp) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        // 尝试完整 mangled 名
        cls = objc_getClass([className UTF8String]);
    }
    if (!cls) {
        FVLog(@"hook failed: class not found: %@", className);
        return NO;
    }
    
    SEL sel = NSSelectorFromString(selectorName);
    if (!sel) {
        FVLog(@"hook failed: selector not found: %@", selectorName);
        return NO;
    }
    
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        FVLog(@"hook failed: method not found: %@[%@]", className, selectorName);
        return NO;
    }
    
    if (origImp) {
        *origImp = method_getImplementation(m);
    }
    method_setImplementation(m, newImp);
    FVLog(@"hooked: %@ [%@]", className, selectorName);
    return YES;
}

// ============================================================================
// Hook 1: ManagedAudioRecorderImpl.stopRecordingWithCompletion:
// ============================================================================

static void (*orig_stopRecordingWithCompletion)(id, SEL, id);

static void hook_stopRecordingWithCompletion(id self, SEL _cmd, id completion) {
    FVLog(@"stopRecordingWithCompletion: called, hasPending=%d",
          [[FakeVoiceManager shared] hasPendingFakeVoice]);
    
    // 先调用原方法（生成录音文件）
    if (orig_stopRecordingWithCompletion) {
        orig_stopRecordingWithCompletion(self, _cmd, completion);
    }
    
    // 如果有待发送的假语音，延迟替换文件
    // 延迟是为了等录音文件完全写入磁盘
    if ([[FakeVoiceManager shared] hasPendingFakeVoice]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            BOOL ok = [[FakeVoiceManager shared] swapRecordingFileForRecorder:self];
            if (ok) {
                FVLog(@"recording file swapped, user can now tap send");
            } else {
                FVLog(@"WARNING: swap failed, voice will be original recording");
            }
        });
    }
}

// ============================================================================
// Hook 2: ManagedAudioRecorderImpl.finishRecording:
//   （备选 hook 点，如果 stopRecordingWithCompletion 不存在则用这个）
// ============================================================================

static void (*orig_finishRecording)(id, SEL, id);

static void hook_finishRecording(id self, SEL _cmd, id arg) {
    FVLog(@"finishRecording: called, hasPending=%d",
          [[FakeVoiceManager shared] hasPendingFakeVoice]);
    
    if (orig_finishRecording) {
        orig_finishRecording(self, _cmd, arg);
    }
    
    if ([[FakeVoiceManager shared] hasPendingFakeVoice]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [[FakeVoiceManager shared] swapRecordingFileForRecorder:self];
        });
    }
}

// ============================================================================
// Hook 3: sendRecordedMedia — 发送后清除待发送状态
// ============================================================================

static void (*orig_sendRecordedMedia)(id, SEL);

static void hook_sendRecordedMedia(id self, SEL _cmd) {
    FVLog(@"sendRecordedMedia called");
    
    // 发送前再确认一次文件已替换（双保险）
    if ([[FakeVoiceManager shared] hasPendingFakeVoice]) {
        [[FakeVoiceManager shared] swapRecordingFileForRecorder:self];
    }
    
    if (orig_sendRecordedMedia) {
        orig_sendRecordedMedia(self, _cmd);
    }
    
    // 发送后清除
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [[FakeVoiceManager shared] clearPending];
    });
}

// ============================================================================
// Hook 4: endRecording — 另一个备选停止点
// ============================================================================

static void (*orig_endRecording)(id, SEL);

static void hook_endRecording(id self, SEL _cmd) {
    FVLog(@"endRecording called, hasPending=%d",
          [[FakeVoiceManager shared] hasPendingFakeVoice]);
    
    if (orig_endRecording) {
        orig_endRecording(self, _cmd);
    }
    
    if ([[FakeVoiceManager shared] hasPendingFakeVoice]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [[FakeVoiceManager shared] swapRecordingFileForRecorder:self];
        });
    }
}

// ============================================================================
// 构造函数：Tweak 入口
// ============================================================================

__attribute__((constructor))
static void tweak_init(void) {
    FVLog(@"=== TelegramVoiceNoteTweak loaded ===");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 安装悬浮按钮
        [[FakeVoiceManager shared] install];
        
        // 尝试 hook 录音器的各个停止/完成方法
        // 不同版本方法名可能不同，逐个尝试，成功一个即可
        
        NSString *recorderClass = @"ManagedAudioRecorderImpl";
        // 备选类名
        NSArray *classCandidates = @[
            @"ManagedAudioRecorderImpl",
            @"_TtC10TelegramUI24ManagedAudioRecorderImpl",
            @"ManagedAudioRecorder",
            @"AudioRecorder",
            @"VoiceRecorder",
        ];
        
        NSString *resolvedClass = nil;
        for (NSString *candidate in classCandidates) {
            if (NSClassFromString(candidate)) {
                resolvedClass = candidate;
                FVLog(@"resolved recorder class: %@", candidate);
                break;
            }
        }
        
        if (!resolvedClass) {
            FVLog(@"ERROR: could not find recorder class, hooks will not work");
            FVLog(@"Please use Frida to find the correct class name");
            return;
        }
        
        // Hook 主要停止方法
        hookInstanceMethod(resolvedClass, @"stopRecordingWithCompletion:",
                           (IMP)hook_stopRecordingWithCompletion,
                           (IMP *)&orig_stopRecordingWithCompletion);
        
        // Hook 备选方法（不影响主要功能，多一层保险）
        hookInstanceMethod(resolvedClass, @"finishRecording:",
                           (IMP)hook_finishRecording,
                           (IMP *)&orig_finishRecording);
        
        hookInstanceMethod(resolvedClass, @"endRecording",
                           (IMP)hook_endRecording,
                           (IMP *)&orig_endRecording);
        
        // Hook 发送方法
        hookInstanceMethod(resolvedClass, @"sendRecordedMedia",
                           (IMP)hook_sendRecordedMedia,
                           (IMP *)&orig_sendRecordedMedia);
        
        FVLog(@"=== hooks installed ===");
    });
}
