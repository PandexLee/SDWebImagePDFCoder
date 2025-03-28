//
//  SDImagePDFCoder.m
//  SDWebImagePDFCoder
//
//  Created by lizhuoli on 2018/10/28.
//

#import "SDImagePDFCoder.h"
#import "SDWebImagePDFCoderDefine.h"
#import "objc/runtime.h"
#import <PDFKit/PDFKit.h>

#define SD_FOUR_CC(c1,c2,c3,c4) ((uint32_t)(((c4) << 24) | ((c3) << 16) | ((c2) << 8) | (c1)))

@interface SDImageIOCoder ()

// From SDWebImage 5.14.1
+ (UIImage *)createBitmapPDFWithData:(nonnull NSData *)data pageNumber:(NSUInteger)pageNumber targetSize:(CGSize)targetSize preserveAspectRatio:(BOOL)preserveAspectRatio;

@end

#if SD_UIKIT || SD_WATCH
static SEL SDImageWithCGPDFPageSEL = NULL;
static SEL SDCGPDFPageSEL = NULL;

static inline NSString *SDBase64DecodedString(NSString *base64String) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64String options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
#endif

@implementation SDImagePDFCoder

#if SD_UIKIT || SD_WATCH
+ (void)initialize {
    SDImageWithCGPDFPageSEL = NSSelectorFromString(SDBase64DecodedString(@"X2ltYWdlV2l0aENHUERGUGFnZTo="));
    SDCGPDFPageSEL = NSSelectorFromString(SDBase64DecodedString(@"X0NHUERGUGFnZQ=="));
}
#endif

+ (SDImagePDFCoder *)sharedCoder {
    static dispatch_once_t onceToken;
    static SDImagePDFCoder *coder;
    dispatch_once(&onceToken, ^{
        coder = [[SDImagePDFCoder alloc] init];
    });
    return coder;
}

- (BOOL)canDecodeFromData:(NSData *)data {
    return [[self class] isPDFFormatForData:data];
}

- (UIImage *)decodedImageWithData:(NSData *)data options:(SDImageCoderOptions *)options {
    if (!data) {
        return nil;
    }
    
    NSUInteger pageNumber = 0;
    BOOL prefersBitmap = NO;
    CGSize imageSize = CGSizeZero;
    BOOL preserveAspectRatio = YES;
    
    // Parse args
    if (options[SDImageCoderDecodePDFPageNumber]) {
        pageNumber = [options[SDImageCoderDecodePDFPageNumber] unsignedIntegerValue];
    }
    if (options[SDImageCoderDecodeThumbnailPixelSize]) {
        prefersBitmap = YES;
        NSValue *sizeValue = options[SDImageCoderDecodeThumbnailPixelSize];
#if SD_MAC
        imageSize = sizeValue.sizeValue;
#else
        imageSize = sizeValue.CGSizeValue;
#endif
    }
    if (options[SDImageCoderDecodePreserveAspectRatio]) {
        preserveAspectRatio = [options[SDImageCoderDecodePreserveAspectRatio] boolValue];
    }
#pragma clang diagnostic pop
    
    UIImage *image;
    if (!prefersBitmap && [self.class supportsVectorPDFImage]) {
        image = [self createVectorPDFWithData:data pageNumber:pageNumber];
    } else {
        NSAssert([SDImageIOCoder respondsToSelector:@selector(createBitmapPDFWithData:pageNumber:targetSize:preserveAspectRatio:)], @"SDWebImage from 5.14.1 should contains this API");
        image = [SDImageIOCoder createBitmapPDFWithData:data pageNumber:pageNumber targetSize:imageSize preserveAspectRatio:preserveAspectRatio];
    }
    
    image.sd_imageFormat = SDImageFormatPDF;
    
    return image;
}


- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    return format == SDImageFormatPDF;
}

- (NSData *)encodedDataWithImage:(UIImage *)image format:(SDImageFormat)format options:(SDImageCoderOptions *)options {
    if (![self.class supportsVectorPDFImage]) {
        return [self.class createPDFDataWithBitmapImage:image];
    }
#if SD_MAC
    // Pixel size use `NSImageRepMatchesDevice` to avoid CGImage bitmap format
    NSRect imageRect = NSMakeRect(0, 0, NSImageRepMatchesDevice, NSImageRepMatchesDevice);
    NSImageRep *imageRep = [image bestRepresentationForRect:imageRect context:nil hints:nil];
    if (![imageRep isKindOfClass:NSPDFImageRep.class]) {
        return [self.class createPDFDataWithBitmapImage:image];
    }
    return ((NSPDFImageRep *)imageRep).PDFRepresentation;
#else
    CGPDFPageRef page = ((CGPDFPageRef (*)(id,SEL))[image methodForSelector:SDCGPDFPageSEL])(image, SDCGPDFPageSEL);
    if (!page) {
        return [self.class createPDFDataWithBitmapImage:image];
    }
    
    // Draw the PDF page using PDFContextToData
    NSMutableData *data = [NSMutableData data];
    CGPDFBox box = kCGPDFCropBox;
    CGRect rect = CGPDFPageGetBoxRect(page, box);
    
    UIGraphicsBeginPDFContextToData(data, CGRectZero, nil);
    UIGraphicsBeginPDFPageWithInfo(rect, nil);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    // Core Graphics Coordinate System convert
    CGContextScaleCTM(context, 1, -1);
    CGContextTranslateCTM(context, 0, -CGRectGetHeight(rect));
    CGContextDrawPDFPage(context, page);
    UIGraphicsEndPDFContext();
    
    return [data copy];
#endif
}

#pragma mark - Vector PDF representation
- (UIImage *)createVectorPDFWithData:(nonnull NSData *)data pageNumber:(NSUInteger)pageNumber {
    NSParameterAssert(data);
    UIImage *image;
    
#if SD_MAC
    // macOS's `NSImage` supports PDF built-in rendering
    NSPDFImageRep *imageRep = [[NSPDFImageRep alloc] initWithData:data];
    if (!imageRep) {
        return nil;
    }
    imageRep.currentPage = pageNumber;
    image = [[NSImage alloc] initWithSize:imageRep.size];
    [image addRepresentation:imageRep];
#else
    
    PDFDocument *document = [[PDFDocument alloc]initWithData:data];
    if (!document) {
        return nil;
    }
    if (pageNumber >= document.pageCount) {
        return nil;
    }
    PDFPage *page = [document pageAtIndex:pageNumber];
    if (!page) {
        return nil;
    }
    
    CGPDFDocumentRef documentRef = document.documentRef;
    if (!documentRef) {
        return nil;
    }
    
    CGPDFPageRef pageRef = page.pageRef;
    if (!pageRef) {
        return nil;
    }

    CGPDFBox box = kCGPDFCropBox;
    CGRect rect = CGPDFPageGetBoxRect(pageRef, box);
    CGAffineTransform transform = CGPDFPageGetDrawingTransform(pageRef, box, rect, 0, YES);
    
    SDGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    CGContextRef context = SDGraphicsGetCurrentContext();
    
#if SD_UIKIT || SD_WATCH
    // Core Graphics coordinate system use the bottom-left, UIKit use the flipped one
    CGContextTranslateCTM(context, 0, rect.size.height);
    CGContextScaleCTM(context, 1, -1);
#endif
    
    CGContextConcatCTM(context, transform);
    [page drawWithBox:kPDFDisplayBoxCropBox toContext:context];

    image = SDGraphicsGetImageFromCurrentImageContext();
    SDGraphicsEndImageContext();
        
#endif
    // png to jpg
    NSData * jpgData = UIImageJPEGRepresentation(image, 1.0);
    if (jpgData) {
        image = [UIImage imageWithData:jpgData];
    } else {
        NSData * pngData = UIImagePNGRepresentation(image);
        if (pngData) {
            jpgData = UIImageJPEGRepresentation([UIImage imageWithData:pngData], 1.0);
            image = [UIImage imageWithData:jpgData];
        }
    }

    return image;
}

#pragma mark - Bitmap PDF creation
+ (NSData *)createPDFDataWithBitmapImage:(UIImage *)image {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) {
        return nil;
    }
    NSMutableData *pdfData = [NSMutableData data];
    CGDataConsumerRef pdfConsumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)pdfData);
    
    CGSize imageSize = CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
    CGRect cropBox = CGRectMake(0, 0, imageSize.width, imageSize.height);
    CGContextRef context = CGPDFContextCreate(pdfConsumer, &cropBox, NULL);
    
    CGContextBeginPage(context, &cropBox);
    CGContextDrawImage(context, cropBox, imageRef);
    CGContextEndPage(context);
    
    return [pdfData copy];
}

+ (BOOL)supportsVectorPDFImage {
#if SD_MAC
    // macOS's `NSImage` supports PDF built-in rendering
    return YES;
#else
    static dispatch_once_t onceToken;
    static BOOL supports;
    dispatch_once(&onceToken, ^{
        // iOS 11+ supports PDF built-in rendering, use selector to check is more accurate
        if ([UIImage respondsToSelector:SDImageWithCGPDFPageSEL]) {
            supports = YES;
        } else {
            supports = NO;
        }
    });
    return supports;
#endif
}

+ (BOOL)isPDFFormatForData:(NSData *)data {
    if (!data) {
        return NO;
    }
    uint32_t magic4;
    [data getBytes:&magic4 length:4]; // 4 Bytes Magic Code for most file format.
    uint32_t ppdf = SD_FOUR_CC('%', 'P', 'D', 'F');
    BOOL eq1 = ppdf == magic4;
    if (eq1) {
        return YES;
    }
    
    NSString *testString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, 5)] encoding:NSASCIIStringEncoding];
    BOOL eq2 = [testString isEqualToString:@" %PDF"];
    if (eq2) {
        return YES;
    }
    return NO;
}

@end
