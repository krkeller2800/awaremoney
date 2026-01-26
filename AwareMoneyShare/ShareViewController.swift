//
//  ShareViewController.swift
//  AwareMoneyShare
//
//  Created by Karl Keller on 1/25/26.
//

import UIKit

final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Do nothing; just close immediately.
        extensionContext?.completeRequest(returningItems: nil)
    }
}

