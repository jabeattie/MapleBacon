//
//  Copyright © 2017 Jan Gorman. All rights reserved.
//

import UIKit

protocol CallCounting {

  var callCount: Int { get }

}

final class TestHelper {

  var image: UIImage {
    return UIImage(named: "MapleBacon", in: Bundle(for: type(of: self).self), compatibleWith: nil)!
  }

  var imageData: Data {
    return image.pngData()!
  }

  func imageResponseData() -> Data {
    return image.pngData()!
  }
  
}

extension String {
  
  func deletingPrefix(_ prefix: String) -> String {
    return String(dropFirst(prefix.count))
  }
  
}

extension URL: ExpressibleByStringLiteral {

  public init(extendedGraphemeClusterLiteral value: String) {
    self = URL(string: value)!
  }

  public init(stringLiteral value: String) {
    self = URL(string: value)!
  }

}
