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

// MARK: - UI constants
private enum UI {
    static let logoSize: CGFloat = 200
    static let headerTopInset: CGFloat = 8
    static let contentHInset: CGFloat = 20
    static let stackSpacing: CGFloat = 16
    static let chipVPad: CGFloat = 12
    static let cardCorner: CGFloat = 14
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
    enum Mode { case upload, viaURL }
    @State private var mode: Mode = .upload
    @State private var isAnalyzing = false
    @State private var result: ScanResult? = nil
    @State private var errorText: String? = nil

    // MARK: - Backend Base URL (Render)
    private let baseURL = "https://aidentify-63bl.onrender.com"

    var body: some View {
        NavigationStack {
            ZStack {
                Image("AppBackground")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: UI.stackSpacing) {
                        // MARK: Header
                        VStack(spacing: 10) {
                            Image("BrandLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: UI.logoSize, height: UI.logoSize)
                                .shadow(radius: 11)
                            Text("")
                                .font(.largeTitle.bold())
                                .foregroundStyle(.primary)
                        }
                        .padding(.top, UI.headerTopInset)

                        // MARK: Mode selection
                        VStack(spacing: 20) {
                            Button {
                                mode = .upload
                            } label: {
                                Label("Upload", systemImage: "tray.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, UI.chipVPad)
                            }
                            .buttonStyle(.bordered)
                            .tint(mode == .upload ? .blue : .gray.opacity(0.35))

                            Button {
                                mode = .viaURL
                            } label: {
                                Label("From URL", systemImage: "link")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, UI.chipVPad)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(mode == .viaURL ? .blue : .gray.opacity(0.35))
                        }

                        // MARK: Panel (upload or URL)
                        Group {
                            if mode == .upload {
                                UploadPane(pickedItems: $pickedItems,
                                           pickedData: $pickedData,
                                           pickedMime: $pickedMime)
                            } else {
                                URLPane(urlString: $urlString)
                            }
                        }

                        // Error
                        if let err = errorText {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // MARK: Analyze button
                        Button {
                            Task { await analyze() }
                        } label: {
                            HStack(spacing: 8) {
                                if isAnalyzing { ProgressView().tint(.white) }
                                Text(isAnalyzing ? "Analyzing…" : "Analyze")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 60)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 50))
                            .shadow(radius: 3)
                        }
                        .disabled(isAnalyzing)
                        .padding(.top, 10)

                        // MARK: Result link
                        if let res = result {
                            NavigationLink("View Result") { ResultView(result: res) }
                                .padding(.top, 4)
                        }

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, UI.contentHInset)
                    .padding(.bottom, 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Analyze function
    private func analyze() async {
        errorText = nil
        result = nil

        switch mode {
        case .upload:
            guard let data = pickedData else {
                errorText = "Please pick an image or video."
                return
            }
            await analyzeUpload(data: data)

        case .viaURL:
            guard urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http") else {
                errorText = "Enter a valid http(s) URL."
                return
            }
            await analyzeURL(urlString)
        }
    }

    // MARK: - Upload Analysis
    private func analyzeUpload(data: Data) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            var req = URLRequest(url: URL(string: "\(baseURL)/analyze/upload")!)
            req.httpMethod = "POST"
            let boundary = "Boundary-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            func append(_ s: String) { body.append(s.data(using: .utf8)!) }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"file\"; filename=\"media.mp4\"\r\n")
            append("Content-Type: application/octet-stream\r\n\r\n")
            body.append(data)
            append("\r\n--\(boundary)--\r\n")
            req.httpBody = body

            let (d, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "api", code: 1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
            }
            let api = try JSONDecoder().decode(APIResult.self, from: d)
            result = mapAPIResult(api)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - URL Analysis
    private func analyzeURL(_ raw: String) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let endpoint = URL(string: "\(baseURL)/analyze/url")!
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = "url=" + (trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            req.httpBody = body.data(using: .utf8)

            let (d, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "api", code: 2, userInfo: [NSLocalizedDescriptionKey: "URL submit failed"])
            }
            let api = try JSONDecoder().decode(APIResult.self, from: d)
            result = mapAPIResult(api)
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Result Mapper
    private func mapAPIResult(_ api: APIResult) -> ScanResult {
        let verdict: ScanResult.Verdict = (api.verdict == "likelyReal") ? .likelyReal :
                                          (api.verdict == "likelyAI") ? .likelyAI : .inconclusive
        return ScanResult(verdict: verdict,
                          confidence: api.confidence,
                          evidence: api.evidence.map { .init(label: $0.label, value: $0.value) })
    }
}

// MARK: - Upload Panel
struct UploadPane: View {
    @Binding var pickedItems: [PhotosPickerItem]
    @Binding var pickedData: Data?
    @Binding var pickedMime: String

    var body: some View {
        VStack(spacing: 20) {
            PhotosPicker(selection: $pickedItems,
                         maxSelectionCount: 1,
                         matching: .any(of: [.videos])) {
                HStack(alignment: .top, spacing: 140) {
                    Image(systemName: "photo.on.rectangle.angled").imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pick video").font(.headline)
                        Text("Needed for upload mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: UI.cardCorner))
            }
            .onChange(of: pickedItems) {
                Task { await loadFirstItem() }
            }

            if let data = pickedData {
                Text("Video selected (\(data.count / 1024) KB)")
                    .foregroundStyle(.secondary)
            } else {
                Text("No media selected yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadFirstItem() async {
        guard let first = pickedItems.first else { return }
        do {
            if let data = try await first.loadTransferable(type: Data.self) {
                pickedData = data
                pickedMime = "video/mp4"
            }
        } catch {
            pickedData = nil
            pickedMime = ""
        }
    }
}

// MARK: - URL Panel
struct URLPane: View {
    @Binding var urlString: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a public video URL (YouTube, Vimeo, etc.)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("https://example.com/video", text: $urlString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
                .padding(.vertical, 20)
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 172)
    }
}

// MARK: - Result View
struct ResultView: View {
    let result: ScanResult
    var verdictText: String {
        switch result.verdict {
        case .likelyAI: return "Likely AI-generated"
        case .likelyReal: return "Likely real"
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
                HStack {
                    Circle().fill(verdictColor).frame(width: 12, height: 12)
                    Text(verdictText).font(.title2).bold()
                    Text("• confidence \(Int(result.confidence * 100))%")
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
#Preview {
    ContentView()
}
