#import "ebgeometry.h"

NSRect EBCenteredRect(NSSize content, NSRect workArea) {
    return NSMakeRect(NSMinX(workArea) + (NSWidth(workArea) - content.width) / 2.0,
                      NSMinY(workArea) + (NSHeight(workArea) - content.height) / 2.0, content.width,
                      content.height);
}

NSSize EBFittedSize(NSSize content, NSRect workArea) {
    CGFloat maxWidth = NSWidth(workArea);
    CGFloat maxHeight = NSHeight(workArea);
    if (maxWidth <= 0 || maxHeight <= 0)
        return NSMakeSize(1, 1);

    if (content.width <= maxWidth && content.height <= maxHeight)
        return content;

    CGFloat scale = MIN(maxWidth / content.width, maxHeight / content.height);
    return NSMakeSize(MAX(1, floor(content.width * scale)), MAX(1, floor(content.height * scale)));
}

NSRect EBBottomRightRect(NSSize content, NSRect workArea, CGFloat inset) {
    return NSMakeRect(NSMaxX(workArea) - content.width - inset, NSMinY(workArea) + inset, content.width,
                      content.height);
}