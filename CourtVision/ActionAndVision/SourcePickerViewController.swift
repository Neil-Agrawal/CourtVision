import UIKit
import AVFoundation

class SourcePickerViewController: UIViewController {

    private let gameManager = GameManager.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        gameManager.stateMachine.enter(GameManager.InactiveState.self)
    }
    
    @IBAction func handleUploadVideoButton(_ sender: Any) {
        let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie], asCopy: true)
        docPicker.delegate = self
        present(docPicker, animated: true)
    }
    
    @IBAction func revertToSourcePicker(_ segue: UIStoryboardSegue) {
        gameManager.reset()
    }
}

extension SourcePickerViewController: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        gameManager.recordedVideoSource = nil
    }
    
    func  documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            return
        }
        gameManager.recordedVideoSource = AVAsset(url: url)
        performSegue(withIdentifier: "ShowRootControllerSegue", sender: self)
    }
}
