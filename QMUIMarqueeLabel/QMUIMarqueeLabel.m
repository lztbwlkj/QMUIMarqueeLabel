/*****
 * Tencent is pleased to support the open source community by making QMUI_iOS available.
 * Copyright (C) 2016-2019 THL A29 Limited, a Tencent company. All rights reserved.
 * Licensed under the MIT License (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at
 * http://opensource.org/licenses/MIT
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
 *****/

//
//  QMUIMarqueeLabel.m
//  qmui
//
//  Created by QMUI Team on 2017/5/31.
//
#import "QMUIMarqueeLabel.h"
//#import "CALayer+QMUI.h"
//#import "NSString+QMUI.h"
#define CGSizeMax CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
#define ScreenScale ([[UIScreen mainScreen] scale])
#define RGBA(R/*红*/, G/*绿*/, B/*蓝*/, A/*透明*/) \
[UIColor colorWithRed:R/255.0f green:G/255.0f blue:B/255.0f alpha:A]
#define RGB(R/*红*/, G/*绿*/, B/*蓝*/) \
[UIColor colorWithRed:R/255.0f green:G/255.0f blue:B/255.0f alpha:1]


@interface QMUIMarqueeLabel ()

@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, assign) CGFloat offsetX;
@property(nonatomic, assign) CGSize textSize;
@property(nonatomic, assign) CGFloat fadeStartPercent; // 渐变开始的百分比，默认为0，不建议改
@property(nonatomic, assign) CGFloat fadeEndPercent; // 渐变结束的百分比，例如0.2，则表示 0~20% 是渐变区间

@property(nonatomic, assign) BOOL isFirstDisplay;

@property(nonatomic, strong) CAGradientLayer *fadeLayer;

/// 绘制文本时重复绘制的次数，用于实现首尾连接的滚动效果，1 表示不首尾连接，大于 1 表示首尾连接。
@property(nonatomic, assign) NSInteger textRepeatCount;

/// 记录上一次布局时的 bounds，如果有改变，则需要重置动画
@property(nonatomic, assign) CGRect prevBounds;

@end

@implementation QMUIMarqueeLabel
CG_INLINE BOOL
betweenOrEqual(CGFloat minimumValue, CGFloat value, CGFloat maximumValue) {
    return minimumValue <= value && value <= maximumValue;
}

/// 用于居中运算
CG_INLINE CGFloat
CGFloatGetCenter(CGFloat parent, CGFloat child) {
    return flat((parent - child) / 2.0);
}

/**
 *  基于当前设备的屏幕倍数，对传进来的 floatValue 进行像素取整。
 *
 *  注意如果在 Core Graphic 绘图里使用时，要注意当前画布的倍数是否和设备屏幕倍数一致，若不一致，不可使用 flat() 函数，而应该用 flatSpecificScale
 */
CG_INLINE CGFloat
flat(CGFloat floatValue) {
    return flatSpecificScale(floatValue, 0);
}

#pragma mark - CGFloat

/**
 *  某些地方可能会将 CGFLOAT_MIN 作为一个数值参与计算（但其实 CGFLOAT_MIN 更应该被视为一个标志位而不是数值），可能导致一些精度问题，所以提供这个方法快速将 CGFLOAT_MIN 转换为 0
 *  issue: https://github.com/Tencent/QMUI_iOS/issues/203
 */
CG_INLINE CGFloat
removeFloatMin(CGFloat floatValue) {
    return floatValue == CGFLOAT_MIN ? 0 : floatValue;
}

/**
 *  基于指定的倍数，对传进来的 floatValue 进行像素取整。若指定倍数为0，则表示以当前设备的屏幕倍数为准。
 *
 *  例如传进来 “2.1”，在 2x 倍数下会返回 2.5（0.5pt 对应 1px），在 3x 倍数下会返回 2.333（0.333pt 对应 1px）。
 */
CG_INLINE CGFloat
flatSpecificScale(CGFloat floatValue, CGFloat scale) {
    floatValue = removeFloatMin(floatValue);
    scale = scale ?: ScreenScale;
    CGFloat flattedValue = ceil(floatValue * scale) / scale;
    return flattedValue;
}



- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.lineBreakMode = NSLineBreakByClipping;
        self.clipsToBounds = YES;// 显示非英文字符时，滚动的时候字符会稍微露出两端，所以这里直接裁剪掉
        
        [self didInitialize];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    if (self = [super initWithCoder:aDecoder]) {
        [self didInitialize];
    }
    return self;
}

- (void)didInitialize {
    self.speed = .5;
    self.fadeStartPercent = 0;
    self.fadeEndPercent = .2;
    self.pauseDurationWhenMoveToEdge = 2.5;
    self.spacingBetweenHeadToTail = 40;
    self.automaticallyValidateVisibleFrame = YES;
    self.shouldFadeAtEdge = YES;
    self.textStartAfterFade = NO;
    
    self.isFirstDisplay = YES;
    self.textRepeatCount = 2;
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
        [self.displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    } else {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    
    // 需要手动触发一下 setter，否则在 xib 赋值 text 后不生效
    self.attributedText = self.attributedText;
}

- (void)setFadeWidthPercent:(CGFloat)fadeWidthPercent {
    if (!betweenOrEqual(0.0, fadeWidthPercent, 1.0)) {
        return;
    }
    _fadeWidthPercent = fadeWidthPercent;
    
    self.fadeEndPercent = fadeWidthPercent;
}

- (void)setText:(NSString *)text {
    [super setText:text];
    self.offsetX = 0;
    self.textSize = [self sizeThatFits:CGSizeMax];
    self.displayLink.paused = ![self shouldPlayDisplayLink];
    [self checkIfShouldShowGradientLayer];
    [self setNeedsLayout];
}

- (void)setAttributedText:(NSAttributedString *)attributedText {
    [super setAttributedText:attributedText];
    self.offsetX = 0;
    self.textSize = [self sizeThatFits:CGSizeMax];
    self.displayLink.paused = ![self shouldPlayDisplayLink];
    [self checkIfShouldShowGradientLayer];
    [self setNeedsLayout];
}

- (void)drawTextInRect:(CGRect)rect {
    CGFloat textInitialX = 0;
    if (self.textAlignment == NSTextAlignmentLeft) {
        textInitialX = 0;
    } else if (self.textAlignment == NSTextAlignmentCenter) {
        textInitialX = MAX(0, CGFloatGetCenter(CGRectGetWidth(self.bounds), self.textSize.width));
    } else if (self.textAlignment == NSTextAlignmentRight) {
        textInitialX = MAX(0, CGRectGetWidth(self.bounds) - self.textSize.width);
    }
    
    // 考虑渐变遮罩的偏移
    CGFloat textOffsetXByFade = 0;
    BOOL shouldTextStartAfterFade = self.shouldFadeAtEdge && self.textStartAfterFade && self.textSize.width > CGRectGetWidth(self.bounds);
    CGFloat fadeWidth = CGRectGetWidth(self.bounds) * .5 * MAX(0, self.fadeEndPercent - self.fadeStartPercent);
    if (shouldTextStartAfterFade && textInitialX < fadeWidth) {
        textOffsetXByFade = fadeWidth;
    }
    textInitialX += textOffsetXByFade;
    
    for (NSInteger i = 0; i < self.textRepeatCountConsiderTextWidth; i++) {
        [self.attributedText drawInRect:CGRectMake(self.offsetX + (self.textSize.width + self.spacingBetweenHeadToTail) * i + textInitialX, CGRectGetMinY(rect) + CGFloatGetCenter(CGRectGetHeight(rect), self.textSize.height), self.textSize.width, self.textSize.height)];
    }
    
    // 自定义绘制就不需要调用 super
//    [super drawTextInRect:rectToDrawAfterAnimated];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    if (self.fadeLayer) {
        self.fadeLayer.frame = self.bounds;
    }
    
    if (!CGSizeEqualToSize(self.prevBounds.size, self.bounds.size)) {
        self.offsetX = 0;
        self.displayLink.paused = ![self shouldPlayDisplayLink];
        self.prevBounds = self.bounds;
        
        [self checkIfShouldShowGradientLayer];
    }
}

- (NSInteger)textRepeatCountConsiderTextWidth {
    if (self.textSize.width < CGRectGetWidth(self.bounds)) {
        return 1;
    }
    return self.textRepeatCount;
}

- (void)handleDisplayLink:(CADisplayLink *)displayLink {
    if (self.offsetX == 0) {
        displayLink.paused = YES;
        [self setNeedsDisplay];
        
        int64_t delay = (self.isFirstDisplay || self.textRepeatCount <= 1) ? self.pauseDurationWhenMoveToEdge : 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            displayLink.paused = ![self shouldPlayDisplayLink];
            if (!displayLink.paused) {
                self.offsetX -= self.speed;
            }
        });
        
        if (delay > 0 && self.textRepeatCount > 1) {
            self.isFirstDisplay = NO;
        }
        
        return;
    }
    
    self.offsetX -= self.speed;
    [self setNeedsDisplay];
    
    if (-self.offsetX >= self.textSize.width + (self.textRepeatCountConsiderTextWidth > 1 ? self.spacingBetweenHeadToTail : 0)) {
        displayLink.paused = YES;
        int64_t delay = self.textRepeatCount > 1 ? self.pauseDurationWhenMoveToEdge : 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.offsetX = 0;
            [self handleDisplayLink:displayLink];
        });
    }
}

- (BOOL)shouldPlayDisplayLink {
    BOOL result = self.window && CGRectGetWidth(self.bounds) > 0 && self.textSize.width > CGRectGetWidth(self.bounds);
    
    // 如果 label.frame 在 window 可视区域之外，也视为不可见，暂停掉 displayLink
    if (result && self.automaticallyValidateVisibleFrame) {
        CGRect rectInWindow = [self.window convertRect:self.frame fromView:self.superview];
        if (!CGRectIntersectsRect(self.window.bounds, rectInWindow)) {
            return NO;
        }
    }
    
    return result;
}

- (void)setShouldFadeAtEdge:(BOOL)shouldFadeAtEdge {
    _shouldFadeAtEdge = shouldFadeAtEdge;
    
    [self checkIfShouldShowGradientLayer];
    [self setNeedsLayout];
}

- (void)checkIfShouldShowGradientLayer {
    BOOL shouldShowFadeLayer = self.window && self.shouldFadeAtEdge && CGRectGetWidth(self.bounds) > 0 && self.textSize.width > CGRectGetWidth(self.bounds);
    
    if (shouldShowFadeLayer) {
        _fadeLayer = [CAGradientLayer layer];
        self.fadeLayer.locations = @[@(self.fadeStartPercent), @(self.fadeEndPercent), @(1 - self.fadeEndPercent), @(1 - self.fadeStartPercent)];
        self.fadeLayer.startPoint = CGPointMake(0, .5);
        self.fadeLayer.endPoint = CGPointMake(1, .5);
        self.fadeLayer.colors = @[(id)RGBA(255, 255, 255, 0).CGColor, (id)RGBA(255, 255, 255, 1).CGColor, (id)RGBA(255, 255, 255, 1).CGColor, (id)RGBA(255, 255, 255, 0).CGColor];
        self.layer.mask = self.fadeLayer;
    } else {
        if (self.layer.mask == self.fadeLayer) {
            self.layer.mask = nil;
        }
    }
}

#pragma mark - Superclass

- (void)setNumberOfLines:(NSInteger)numberOfLines {
    numberOfLines = 1;
    [super setNumberOfLines:numberOfLines];
}

@end

@implementation QMUIMarqueeLabel (ReusableView)

- (BOOL)requestToStartAnimation {
    self.automaticallyValidateVisibleFrame = NO;
    BOOL shouldPlayDisplayLink = [self shouldPlayDisplayLink];
    if (shouldPlayDisplayLink) {
        self.displayLink.paused = NO;
    }
    return shouldPlayDisplayLink;
}

- (BOOL)requestToStopAnimation {
    self.displayLink.paused = YES;
    return YES;
}


@end

