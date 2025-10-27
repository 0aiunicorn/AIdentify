import SwiftUI
import PhotosUI

// MARK: - API DTOs
struct APIResult: Decodable {
    let verdict: String          // "likelyAI" | "likelyReal" | "inconclusive"
    let confidence: Double       // 0.0 ... 1.0
    let evidence: [Evidence]

    struct Evidence: Decodable, Identifiable {
        var id: UUID { UUID() }
        let label: String
        let value: String
    }
}

// MARK: - App Models
struct ScanResult {
    enum Verdict { case likelyAI, likelyReal, inconclusive }
    let verdict: Verdict
    let confidence: Double
    let evidence: [Evidence]
    struct Evidence: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }
}

// MARK: - Main View
struct ContentView: View {
    // Media picking
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pickedData: Data? = nil
    @State private var pickedMime: String = ""

    // URL scan
    @State private var urlString: String = ""

    // State
    @State private var mode: Mode = .upload
    @State private var isAnalyzing = false
    @State private var result: ScanResult? = nil
    @State private var errorText: String? = nil

    enum Mode { case upload, viaURL }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $mode) {
                    Text("Upload").tag(Mode.upload)
                    Text("From URL").tag(Mode.viaURL)
                }
                .pickerStyle(.segmented)
                .padding(.top)

                if mode == .upload {
                    UploadPane(pickedItems: $pickedItems, pickedData: $pickedData, pickedMime: $pickedMime)
                } else {
                    URLPane(urlString: $urlString)
                }

                if let err = errorText {
                    Text(err).foregroundStyle(.red).font(.footnote)
                }

                Button {
                    Task { await analyze() }
                } label: {
                    HStack {
                        if isAnalyzing { ProgressView().tint(.white) }
                        Text(isAnalyzing ? "Analyzing…" : "Analyze")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAnalyzing)

                if let res = result {
                    NavigationLink("View Result") { ResultView(result: res) }
                        .padding(.top, 4)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("AI Identifier")
        }
    }

    // MARK: - Analysis
    private func analyze() async {
        errorText = nil
        result = nil

        // Validate inputs
        switch mode {
        case .upload:
            guard let data = pickedData else {
                errorText = "Please pick an image or video."
                return
            }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let api = try await uploadToAPI(data: data)
                result = mapAPIResult(api)
            } catch {
                errorText = error.localizedDescription
            }

        case .viaURL:
            guard urlString.lowercased().hasPrefix("http") else {
                errorText = "Enter a valid http(s) URL."
                return
            }
            isAnalyzing = true
            defer { isAnalyzing = false }
            do {
                let api = try await submitURLToAPI(urlString)
                result = mapAPIResult(api)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func mapAPIResult(_ api: APIResult) -> ScanResult {
        let verdict: ScanResult.Verdict = (api.verdict == "likelyReal") ? .likelyReal :
                                          (api.verdict == "likelyAI")  ? .likelyAI  :
                                                                          .inconclusive
        return ScanResult(
            verdict: verdict,
            confidence: api.confidence,
            evidence: api.evidence.map { .init(label: $0.label, value: $0.value) }
        )
    }

    // MARK: - Networking
    private func uploadToAPI(data: Data) async throws -> APIResult {
        // Change to your server’s base URL if needed
        let url = URL(string: "https://aidentify-63bl.onrender.com/analyze/upload")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"media.bin\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        req.httpBody = body

        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "api", code: 1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }
        return try JSONDecoder().decode(APIResult.self, from: d)
    }

    private func submitURLToAPI(_ urlString: String) async throws -> APIResult {
        let url = URL(string: "https://aidentify-63bl.onrender.com/analyze/url")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body = "url=" + (urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        req.httpBody = body.data(using: .utf8)

        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "api", code: 2, userInfo: [NSLocalizedDescriptionKey: "URL submit failed"])
        }
        return try JSONDecoder().decode(APIResult.self, from: d)
    }
}

// MARK: - Subviews

struct UploadPane: View {
    @Binding var pickedItems: [PhotosPickerItem]
    @Binding var pickedData: Data?
    @Binding var pickedMime: String

    var body: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $pickedItems, maxSelectionCount: 1, matching: .any(of: [.images, .videos])) {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled").imageScale(.large)
                    VStack(alignment: .leading) {
                        Text("Pick image or video").font(.headline)
                        Text("Needed for upload mode").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .onChange(of: pickedItems) {
                Task { await loadFirstItem() }
            }

            if let data = pickedData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if pickedData != nil {
                HStack(spacing: 12) {
                    Image(systemName: "video").imageScale(.large)
                    Text("Video selected (preview omitted)")
                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text("No media selected yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func loadFirstItem() async {
        guard let first = pickedItems.first else { return }
        do {
            if let data = try await first.loadTransferable(type: Data.self) {
                pickedData = data
                // Simple MIME guess: if it decodes as an image, call it jpeg; else assume mp4
                if UIImage(data: data) != nil {
                    pickedMime = "image/jpeg"
                } else {
                    pickedMime = "video/mp4"
                }
            }
        } catch {
            pickedData = nil
            pickedMime = ""
        }
    }
}

struct URLPane: View {
    @Binding var urlString: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a public video URL (YouTube, direct MP4, etc.)")
                .font(.subheadline)
            TextField("https://…", text: $urlString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textContentType(.URL)
                .keyboardType(.URL)
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Result View
struct ResultView: View {
    let result: ScanResult

    var verdictText: String {
        switch result.verdict {
        case .likelyAI: return "Likely AI-generated"
        case .likelyReal: return "Likely real / captured"
        case .inconclusive: return "Inconclusive"
        }
    }
    var verdictColor: Color {
        switch result.verdict {
        case .likelyAI: return .orange
        case .likelyReal: return .green
        case .inconclusive: return .gray
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(verdictColor).frame(width: 12, height: 12)
                    Text(verdictText).font(.title2).bold()
                    Text("• confidence \(Int((result.confidence*100).rounded()))%")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Evidence").font(.headline)
                    ForEach(result.evidence) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.label).font(.subheadline).bold()
                            Text(e.value).font(.subheadline)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Scan Result")
    }
}

