import Cocoa
import FlutterMacOS

public class CustomMouseCursorPlugin: NSObject, FlutterPlugin {
  private var caches: Dictionary = [String: NSCursor]();
    
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "custom_mouse_cursor", binaryMessenger: registrar.messenger)
    let instance = CustomMouseCursorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createCustomCursor":
        let arguments = call.arguments as! Dictionary<String, Any>
        let ret = createCustomCursor(arguments)
        if (ret == nil) {
            result(FlutterError(code: "-1", message: "Create the cursor failed", details: "Please ensure a PNG encoded image buffer is provided."))
        } else {
            result(ret!)
        }
        break
    case "setCustomCursor":
        let arguments = call.arguments as! Dictionary<String, Any>
        let ret = setCustomCursor(arguments)
        if ret {
            result(nil)
        } else {
            result(FlutterError(code: "-1", message: "Set the cursor failed", details: "Cursor name not found in table.  Please use createCustomCursor to create a cursor."))
        }
        break
    case "deleteCustomCursor":
        let arguments = call.arguments as! Dictionary<String, Any>
        let _ = deleteCustomCursor(arguments)
        result(nil)
        break
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func createCustomCursor(_ arguments: Dictionary<String, Any>) -> String? {
    let name = arguments["name"] as! String
    let buffer = [UInt8]((arguments["buffer"] as! FlutterStandardTypedData).data)
    let hotX = arguments["hotX"] as! Double
    let hotY = arguments["hotY"] as! Double
    let width = arguments["width"] as! Int
    let height = arguments["height"] as! Int
    // ICARUS PATCH: `scale` is how many bitmap pixels represent one logical
    // point (the devicePixelRatio the Dart side rendered the image at).
    let scale = arguments["scale"] as? Double ?? 1.0
    let image = memoryFromImage(data: Data(buffer))
    if (image == nil) {
        return nil;
    }
    // Setting the NSImage point size smaller than its pixel size is what
    // makes AppKit treat the bitmap as high-DPI: a 24px image with a 12pt
    // size renders as a crisp 12pt cursor on Retina displays instead of a
    // scaled-up 1x image. NSCursor's hot spot is in points as well.
    image!.size = NSSize(width: Double(width) / scale, height: Double(height) / scale)
    let cursor = getCursorFromImage(image: image!, x: hotX / scale, y: hotY / scale)
    caches[name] = cursor;
    return name
  }
    
  private func setCustomCursor(_ arguments: Dictionary<String,Any>) -> Bool {
    let name = arguments["name"] as! String
    let cursor = caches[name];
    if (cursor == nil) {
        return false
    }
    cursor!.set()
    return true
  }
    
  private func deleteCustomCursor(_ arguments: Dictionary<String,Any>) -> Bool {
    let name = arguments["name"] as! String
    let cursor = caches[name];
    if (cursor == nil) {
        return false
    }
    caches.removeValue(forKey: name)
    return true
  }
    
    private func activateMemoryImageCursor(_ arguments: Dictionary<String,Any>) {
        let buffer = arguments["buffer"] as! FlutterStandardTypedData
        let byte = [UInt8](buffer.data);
        var image = memoryFromImage(data: Data(byte))
        if (image == nil) {
            return
        }
        // TODO: no scale on macOS currently
        if (arguments["scale_x"] as! Int != -1) {
            image = resize(image: image!, w: arguments["scale_x"] as! Int, h: arguments["scale_y"] as! Int)
        }
        let cursor = getCursorFromImage(image: image!, x: arguments["x"] as? Double, y: arguments["y"] as? Double)
        cursor.set()
    }
 
    private func activeCursor(_ arguments: Dictionary<String,Any>) {
        let path = arguments["path"] as! String
        let fullPath = Bundle.main.bundlePath + "/Contents/Frameworks/App.framework/Resources/flutter_assets/" + path
        let cursor = getCursorFromFile(path:fullPath,
                               x:arguments["x"] as? Double,
                               y:arguments["y"] as? Double)
        cursor?.set()
    }
    
    private func resize(image: NSImage, w: Int, h: Int) -> NSImage {
//        var destSize = NSMakeSize(CGFloat(w), CGFloat(h))
//        var newImage = NSImage(size: destSize)
//        newImage.lockFocus()
//        image.drawInRect(NSMakeRect(0, 0, destSize.width, destSize.height), fromRect: NSMakeRect(0, 0, image.size.width, image.size.height), operation: NSCompositingOperation.CompositeSourceOver, fraction: CGFloat(1))
//        newImage.unlockFocus()
//        newImage.size = destSize
        return image
    }
    
    
    private func getCursorFromFile(path:String,x:Double?,y:Double?) -> NSCursor? {
        var cursor = caches[path]
        if(cursor != nil) {
            return cursor!
        }
        let img = imageFromFile(named: path)
        if(img == nil) {
            return nil
        }
        cursor = getCursorFromImage(image: img!, x: x, y: y)
        caches[path] = cursor
        return cursor!
    }
    
    private func getCursorFromImage(image: NSImage,x:Double?,y:Double?) -> NSCursor {
        var dx = x;
        var dy = y;
        if(dx == nil) {
            dx = Double(image.size.width) / 2;
        }
        if(dy == nil) {
            dy = Double(image.size.height) / 2;
        }
        let cursor = NSCursor.init(image: image,
                               hotSpot:NSMakePoint(CGFloat(dx!),CGFloat(dy!)))
        return cursor
    }
    
    private func imageFromFile(named:String) -> NSImage?{
        return NSImage.init(contentsOfFile:"\(named)");
    }
    
    private func memoryFromImage(data: Data) -> NSImage? {
        return NSImage.init(data: data)
    }

/*
    // https://stackoverflow.com/questions/19245387/nscursor-using-high-resolution-cursors-with-cursor-zoom-or-retina
    private func hintedCursor(image:NSImage) -> NSCursor? {
        //NSImage *   theImage = [NSImage imageNamed: @"CURS_128.pdf"];

        NSImage *resultImage = [[NSImage alloc] initWithSize:[theImage size]];

        for (int scale = 1; scale <= 4; scale++) {
            NSAffineTransform *xform = [[NSAffineTransform alloc] init];
            [xform scaleBy:scale];
            id hints = @{ NSImageHintCTM: xform };
            CGImageRef rasterCGImage = [theImage CGImageForProposedRect:NULL context:nil hints:hints];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:rasterCGImage];
            [rep setSize:[theImage size]];
            [resultImage addRepresentation:rep];
        }

        NSCursor*   theCursor = [[NSCursor alloc] initWithImage: resultImage hotSpot: NSMakePoint(12,8)];
        //[self.scrollView setDocumentCursor: theCursor];
        return theCursor;
    }
*/

}
