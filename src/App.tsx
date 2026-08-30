import {
  Archive,
  Check,
  ChevronDown,
  Clipboard,
  Clock3,
  Command,
  Copy,
  FileImage,
  FolderKanban,
  ImagePlus,
  Inbox,
  Library,
  LoaderCircle,
  MoreHorizontal,
  Plus,
  Search,
  Settings,
  Sparkles,
  SquareTerminal,
  Trash2,
  UploadCloud,
  X,
} from "lucide-react";
import {
  ChangeEvent,
  DragEvent,
  FormEvent,
  KeyboardEvent,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createWorker } from "tesseract.js";

type Model = "Codex" | "Claude" | "Grok" | "Other";

type Session = {
  id: string;
  model: Model;
  project: string;
  description: string;
  command: string;
  createdAt: string;
  sourceName?: string;
  detected: boolean;
};

type CaptureDraft = {
  model: Model;
  project: string;
  description: string;
  command: string;
};

const MODELS: Model[] = ["Codex", "Claude", "Grok", "Other"];

const MODEL_META: Record<Model, { mark: string; tone: string; hint: string }> = {
  Codex: { mark: "C", tone: "codex", hint: "codex --resume" },
  Claude: { mark: "A", tone: "claude", hint: "claude --resume" },
  Grok: { mark: "G", tone: "grok", hint: "grok --resume" },
  Other: { mark: ">", tone: "other", hint: "tool --resume" },
};

const SAMPLE_SESSIONS: Session[] = [
  {
    id: "seed-1",
    model: "Codex",
    project: "Billing portal",
    description: "Stripe webhook retries and the failed payment timeline.",
    command: 'codex --resume "019cba47-918e-7ca2-85b8-cc71d11a5e42"',
    createdAt: "2026-08-30T08:42:00.000Z",
    sourceName: "terminal-billing.png",
    detected: true,
  },
  {
    id: "seed-2",
    model: "Codex",
    project: "Search indexing",
    description: "Continue profiling the incremental Meilisearch sync.",
    command: 'codex --resume "019cb5ec-e7ff-7ce0-842b-29b566f95c4c"',
    createdAt: "2026-08-29T15:17:00.000Z",
    detected: true,
  },
  {
    id: "seed-3",
    model: "Claude",
    project: "iOS onboarding",
    description: "Refine passkey setup and error recovery states.",
    command: 'claude --resume "4d4e9441-f029-4275-82e5-5d904ba427e6"',
    createdAt: "2026-08-28T12:04:00.000Z",
    sourceName: "Screenshot 2026-08-28.png",
    detected: true,
  },
  {
    id: "seed-4",
    model: "Grok",
    project: "Deploy monitor",
    description: "Investigate the production health-check timeout.",
    command: 'grok --resume "session_b97d0043f6"',
    createdAt: "2026-08-27T19:31:00.000Z",
    detected: false,
  },
];

const EMPTY_DRAFT: CaptureDraft = {
  model: "Codex",
  project: "",
  description: "",
  command: "",
};

const STORAGE_KEY = "reprise-sessions-v1";

function readSessions(): Session[] {
  try {
    const value = localStorage.getItem(STORAGE_KEY);
    return value ? (JSON.parse(value) as Session[]) : SAMPLE_SESSIONS;
  } catch {
    return SAMPLE_SESSIONS;
  }
}

function detectModel(text: string): Model {
  const source = text.toLowerCase();
  if (/\bclaude\b|anthropic/.test(source)) return "Claude";
  if (/\bgrok\b|x\.ai/.test(source)) return "Grok";
  if (/\bcodex\b|openai/.test(source)) return "Codex";
  return "Other";
}

function extractCommand(text: string, model: Model): string {
  const normalized = text
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .replace(/\r/g, "");
  const lines = normalized.split("\n").map((line) => line.trim());
  const tool = model === "Other" ? "(?:codex|claude|grok|[a-z][\\w.-]+)" : model.toLowerCase();
  const commandPattern = new RegExp(
    `(?:^|[>$#]\\s*)(${tool}\\s+(?:--resume|resume)\\s+(?:["']?[\\w./:@-]+["']?))`,
    "i",
  );

  for (const line of lines) {
    const match = line.match(commandPattern);
    if (match) return match[1].replace(/\s+/g, " ").trim();
  }

  const idPattern = /(?:resume|session(?:\s+id)?)\s*[:=#-]?\s*["']?([a-z0-9][\w-]{7,})["']?/i;
  const id = normalized.match(idPattern)?.[1];
  if (!id || model === "Other") return "";
  return `${model.toLowerCase()} --resume "${id}"`;
}

function relativeDate(value: string): string {
  const then = new Date(value).getTime();
  const hours = Math.max(0, Math.floor((Date.now() - then) / 3_600_000));
  if (hours < 1) return "just now";
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return "yesterday";
  if (days < 7) return `${days}d ago`;
  return new Intl.DateTimeFormat("en", { month: "short", day: "numeric" }).format(new Date(value));
}

function ModelMark({ model, size = "regular" }: { model: Model; size?: "small" | "regular" }) {
  const meta = MODEL_META[model];
  return (
    <span className={`model-mark ${meta.tone} ${size}`} aria-hidden="true">
      {meta.mark}
    </span>
  );
}

function App() {
  const [sessions, setSessions] = useState<Session[]>(readSessions);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<Model | "All">("All");
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [globalDrag, setGlobalDrag] = useState(false);
  const [toDelete, setToDelete] = useState<string | null>(null);
  const [pendingCaptureFile, setPendingCaptureFile] = useState<File | null>(null);
  const captureDialog = useRef<HTMLDialogElement>(null);
  const deleteDialog = useRef<HTMLDialogElement>(null);
  const dragCounter = useRef(0);

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(sessions));
  }, [sessions]);

  useEffect(() => {
    const onEnter = (event: globalThis.DragEvent) => {
      if (!event.dataTransfer?.types.includes("Files")) return;
      dragCounter.current += 1;
      setGlobalDrag(true);
    };
    const onLeave = () => {
      dragCounter.current -= 1;
      if (dragCounter.current <= 0) {
        dragCounter.current = 0;
        setGlobalDrag(false);
      }
    };
    const onDragOver = (event: globalThis.DragEvent) => {
      if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
    };
    const onDrop = (event: globalThis.DragEvent) => {
      if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
      dragCounter.current = 0;
      setGlobalDrag(false);
    };
    window.addEventListener("dragenter", onEnter);
    window.addEventListener("dragleave", onLeave);
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("drop", onDrop);
    return () => {
      window.removeEventListener("dragenter", onEnter);
      window.removeEventListener("dragleave", onLeave);
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("drop", onDrop);
    };
  }, []);

  useEffect(() => {
    const onShortcut = (event: globalThis.KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey)) return;
      if (event.key.toLowerCase() === "n") {
        event.preventDefault();
        openCapture();
      }
      if (event.key.toLowerCase() === "k") {
        event.preventDefault();
        document.querySelector<HTMLInputElement>(".search-input")?.focus();
      }
    };
    window.addEventListener("keydown", onShortcut);
    return () => window.removeEventListener("keydown", onShortcut);
  }, []);

  const filteredSessions = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return sessions.filter((session) => {
      const modelMatch = filter === "All" || session.model === filter;
      const textMatch =
        !needle ||
        [session.project, session.description, session.command, session.model]
          .join(" ")
          .toLowerCase()
          .includes(needle);
      return modelMatch && textMatch;
    });
  }, [filter, query, sessions]);

  const grouped = useMemo(
    () =>
      MODELS.map((model) => ({
        model,
        sessions: filteredSessions.filter((session) => session.model === model),
      })).filter((group) => group.sessions.length > 0),
    [filteredSessions],
  );

  function openCapture(nextFile?: File) {
    setMenuOpen(false);
    if (nextFile) setPendingCaptureFile(nextFile);
    captureDialog.current?.showModal();
  }

  async function copyCommand(session: Session) {
    try {
      await navigator.clipboard.writeText(session.command);
      setCopiedId(session.id);
      window.setTimeout(() => setCopiedId(null), 1600);
    } catch {
      const textarea = document.createElement("textarea");
      textarea.value = session.command;
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      textarea.remove();
      setCopiedId(session.id);
      window.setTimeout(() => setCopiedId(null), 1600);
    }
  }

  function requestDelete(id: string) {
    setToDelete(id);
    deleteDialog.current?.showModal();
  }

  function confirmDelete() {
    if (toDelete) setSessions((current) => current.filter((session) => session.id !== toDelete));
    setToDelete(null);
    deleteDialog.current?.close();
  }

  const counts = MODELS.reduce<Record<string, number>>((acc, model) => {
    acc[model] = sessions.filter((session) => session.model === model).length;
    return acc;
  }, {});

  return (
    <div className={`app ${globalDrag ? "is-dragging" : ""}`}>
      <header className="menu-bar">
        <div className="menu-left">
          <button className="brand-trigger" onClick={() => setMenuOpen((value) => !value)} aria-expanded={menuOpen}>
            <span className="brand-glyph"><SquareTerminal size={15} strokeWidth={2.2} /></span>
            <span>Reprise</span>
            <ChevronDown size={12} />
          </button>
          <span className="menu-label">Library</span>
          <span className="menu-label">Capture</span>
        </div>
        <div className="menu-right">
          <button
            className={`menubar-drop-target ${globalDrag ? "ready" : ""}`}
            onClick={() => openCapture()}
            onDragOver={(event) => event.preventDefault()}
            onDrop={(event) => {
              event.preventDefault();
              const nextFile = event.dataTransfer.files[0];
              openCapture(nextFile);
            }}
            title="Drop a terminal screenshot"
          >
            {globalDrag ? <UploadCloud size={16} /> : <ImagePlus size={15} />}
            <span>{globalDrag ? "Drop screenshot" : "Capture"}</span>
          </button>
          <span className="menu-time">Sun Aug 30&nbsp;&nbsp; 14:26</span>
        </div>
        {menuOpen && (
          <div className="app-menu" role="menu">
            <button role="menuitem" onClick={() => openCapture()}><ImagePlus size={15} /> New capture <kbd>⌘N</kbd></button>
            <button role="menuitem" onClick={() => document.querySelector<HTMLInputElement>(".search-input")?.focus()}><Search size={15} /> Search library <kbd>⌘K</kbd></button>
            <div className="menu-divider" />
            <button role="menuitem" onClick={() => setMenuOpen(false)}><Settings size={15} /> Preferences</button>
          </div>
        )}
      </header>

      <div className="window-shell">
        <aside className="sidebar">
          <div className="traffic-lights" aria-hidden="true"><i /><i /><i /></div>
          <div className="product-lockup">
            <span className="product-icon"><Command size={18} /></span>
            <div><strong>Reprise</strong><span>Session notebook</span></div>
          </div>

          <nav aria-label="Primary navigation">
            <p className="nav-heading">Workspace</p>
            <button className="nav-item active" onClick={() => setFilter("All")}>
              <Library size={16} /><span>Library</span><b>{sessions.length}</b>
            </button>
            <button className="nav-item" onClick={() => openCapture()}>
              <Inbox size={16} /><span>Inbox</span><b>0</b>
            </button>

            <p className="nav-heading with-action">Assistants <button title="Add a new assistant"><Plus size={14} /></button></p>
            {MODELS.filter((model) => model !== "Other" || counts[model] > 0).map((model) => (
              <button
                className={`nav-item model-filter ${filter === model ? "selected" : ""}`}
                key={model}
                onClick={() => setFilter(model)}
              >
                <ModelMark model={model} size="small" /><span>{model}</span><b>{counts[model]}</b>
              </button>
            ))}
          </nav>

          <div className="sidebar-note">
            <span className="privacy-dot" />
            <div><strong>Stored locally</strong><span>Your commands never leave this device.</span></div>
          </div>
          <button className="settings-link"><Settings size={16} /> Preferences</button>
        </aside>

        <main className="workspace">
          <section className="workspace-header">
            <div>
              <div className="eyebrow"><Archive size={13} /> Session archive</div>
              <h1>{filter === "All" ? "Resume library" : filter}</h1>
              <p>{sessions.length} saved sessions across {new Set(sessions.map((session) => session.model)).size} assistants</p>
            </div>
            <div className="header-actions">
              <label className="search-box">
                <Search size={16} />
                <input
                  className="search-input"
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder="Search projects or commands"
                  aria-label="Search sessions"
                />
                <kbd>⌘K</kbd>
              </label>
              <button className="primary-button" onClick={() => openCapture()}><ImagePlus size={16} /> Capture session</button>
            </div>
          </section>

          <section className="quick-strip" aria-label="Quick capture">
            <div className="quick-icon"><Sparkles size={18} /></div>
            <div><strong>Turn a terminal screenshot into a shortcut.</strong><span>Drop it on the Reprise icon above—we’ll read the command and sort it automatically.</span></div>
            <button onClick={() => openCapture()}>Choose screenshot <ChevronDown size={14} /></button>
          </section>

          <section className="library-content" aria-live="polite">
            {grouped.length ? (
              grouped.map((group) => (
                <div className="session-group" key={group.model}>
                  <div className="group-heading">
                    <div><ModelMark model={group.model} /><h2>{group.model}</h2><span>{group.sessions.length}</span></div>
                    <button title={`More options for ${group.model}`}><MoreHorizontal size={18} /></button>
                  </div>
                  <div className="session-list">
                    {group.sessions.map((session) => (
                      <article className="session-row" key={session.id}>
                        <div className="session-project">
                          <span className="folder-icon"><FolderKanban size={16} /></span>
                          <div>
                            <h3>{session.project}</h3>
                            <p>{session.description || "No project notes yet."}</p>
                          </div>
                        </div>
                        <div className="command-capsule">
                          <span className="prompt-mark">$</span>
                          <code>{session.command}</code>
                          <button onClick={() => copyCommand(session)} title="Copy resume command">
                            {copiedId === session.id ? <Check size={15} /> : <Copy size={15} />}
                          </button>
                        </div>
                        <div className="session-meta">
                          <span title={new Date(session.createdAt).toLocaleString()}><Clock3 size={13} /> {relativeDate(session.createdAt)}</span>
                          <span className={session.detected ? "auto-tag" : "manual-tag"}>{session.detected ? "Auto" : "Manual"}</span>
                          <button className="delete-button" onClick={() => requestDelete(session.id)} title="Delete session"><Trash2 size={15} /></button>
                        </div>
                      </article>
                    ))}
                  </div>
                </div>
              ))
            ) : (
              <div className="empty-state">
                <span><Search size={22} /></span>
                <h2>No sessions found</h2>
                <p>Try another search or capture a new terminal screenshot.</p>
                <button className="secondary-button" onClick={() => { setQuery(""); setFilter("All"); }}>Clear filters</button>
              </div>
            )}
          </section>
        </main>
      </div>

      {globalDrag && (
        <div className="drag-signal" aria-hidden="true">
          <UploadCloud size={18} />
          Reprise is ready for your screenshot
        </div>
      )}

      <CaptureDialog
        dialogRef={captureDialog}
        initialFile={pendingCaptureFile}
        onInitialFileConsumed={() => setPendingCaptureFile(null)}
        onSave={(session) => setSessions((current) => [session, ...current])}
      />

      <dialog className="confirm-dialog" ref={deleteDialog} onClick={(event) => {
        if (event.target === event.currentTarget) event.currentTarget.close();
      }}>
        <div className="confirm-content">
          <span className="danger-icon"><Trash2 size={18} /></span>
          <h2>Delete this session?</h2>
          <p>The saved command and project note will be removed from this device.</p>
          <div className="confirm-actions">
            <button className="secondary-button" onClick={() => deleteDialog.current?.close()}>Cancel</button>
            <button className="danger-button" onClick={confirmDelete}>Delete session</button>
          </div>
        </div>
      </dialog>
    </div>
  );
}

function CaptureDialog({
  dialogRef,
  initialFile,
  onInitialFileConsumed,
  onSave,
}: {
  dialogRef: React.RefObject<HTMLDialogElement | null>;
  initialFile: File | null;
  onInitialFileConsumed: () => void;
  onSave: (session: Session) => void;
}) {
  const [draft, setDraft] = useState<CaptureDraft>(EMPTY_DRAFT);
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [stage, setStage] = useState<"drop" | "reading" | "review">("drop");
  const [progress, setProgress] = useState(0);
  const [detected, setDetected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);

  useEffect(() => {
    if (!initialFile) return;
    void acceptFile(initialFile);
    onInitialFileConsumed();
  }, [initialFile]);

  function reset() {
    if (preview) URL.revokeObjectURL(preview);
    setDraft(EMPTY_DRAFT);
    setFile(null);
    setPreview(null);
    setStage("drop");
    setProgress(0);
    setDetected(false);
    setError(null);
  }

  function close() {
    dialogRef.current?.close();
    window.setTimeout(reset, 180);
  }

  async function acceptFile(nextFile: File) {
    if (!nextFile.type.startsWith("image/")) {
      setError("Please choose a PNG, JPG, or WebP screenshot.");
      return;
    }
    if (nextFile.size > 12 * 1024 * 1024) {
      setError("That screenshot is larger than 12 MB.");
      return;
    }

    setError(null);
    setFile(nextFile);
    if (preview) URL.revokeObjectURL(preview);
    setPreview(URL.createObjectURL(nextFile));
    setStage("reading");
    setProgress(8);

    try {
      const worker = await createWorker("eng", 1, {
        logger: (message) => {
          if (message.status === "recognizing text") setProgress(Math.max(12, Math.round(message.progress * 100)));
        },
      });
      const result = await worker.recognize(nextFile);
      await worker.terminate();
      const text = result.data.text;
      const model = detectModel(text);
      const command = extractCommand(text, model);
      setDraft((current) => ({
        ...current,
        model,
        command,
        project: nextFile.name.replace(/\.(png|jpe?g|webp)$/i, "").replace(/^screenshot[\s_-]*/i, ""),
      }));
      setDetected(Boolean(command && model !== "Other"));
      setProgress(100);
      setStage("review");
    } catch {
      setDraft((current) => ({
        ...current,
        project: nextFile.name.replace(/\.(png|jpe?g|webp)$/i, ""),
      }));
      setError("We couldn’t read this image automatically. Add the model and command below.");
      setStage("review");
    }
  }

  function onInput(event: ChangeEvent<HTMLInputElement>) {
    const nextFile = event.target.files?.[0];
    if (nextFile) void acceptFile(nextFile);
    event.target.value = "";
  }

  function onDrop(event: DragEvent<HTMLDivElement>) {
    event.preventDefault();
    const nextFile = event.dataTransfer.files[0];
    if (nextFile) void acceptFile(nextFile);
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!draft.command.trim()) {
      setError("Add the resume command before saving.");
      return;
    }
    onSave({
      id: crypto.randomUUID(),
      ...draft,
      project: draft.project.trim() || "Untitled project",
      description: draft.description.trim(),
      command: draft.command.trim(),
      createdAt: new Date().toISOString(),
      sourceName: file?.name,
      detected,
    });
    close();
  }

  function onDialogKeyDown(event: KeyboardEvent<HTMLDialogElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      close();
    }
  }

  return (
    <dialog
      className="capture-dialog"
      ref={dialogRef}
      onKeyDown={onDialogKeyDown}
      onClick={(event) => { if (event.target === event.currentTarget) close(); }}
    >
      <form onSubmit={submit}>
        <div className="dialog-header">
          <div><span className="dialog-glyph"><ImagePlus size={18} /></span><div><h2>Capture a session</h2><p>Screenshot → resume command</p></div></div>
          <button type="button" onClick={close} title="Close"><X size={18} /></button>
        </div>

        {stage === "drop" && (
          <div className="capture-body">
            <div
              className="drop-zone"
              onDragOver={(event) => event.preventDefault()}
              onDrop={onDrop}
              onClick={() => inputRef.current?.click()}
            >
              <input ref={inputRef} type="file" accept="image/png,image/jpeg,image/webp" onChange={onInput} hidden />
              <span className="drop-icon"><UploadCloud size={25} /></span>
              <h3>Drop your terminal screenshot</h3>
              <p>We’ll find the model and resume command automatically.</p>
              <button type="button" className="secondary-button" onClick={(event) => { event.stopPropagation(); inputRef.current?.click(); }}>
                <FileImage size={15} /> Choose screenshot
              </button>
              <span className="file-hint">PNG, JPG or WebP · up to 12 MB</span>
            </div>
            {error && <p className="form-error">{error}</p>}
            <div className="supported-row">
              <span>Auto-detects</span>
              {MODELS.slice(0, 3).map((model) => <span key={model}><ModelMark model={model} size="small" /> {model}</span>)}
            </div>
          </div>
        )}

        {stage === "reading" && (
          <div className="reading-state">
            <div className="preview-frame">{preview && <img src={preview} alt="Terminal screenshot being read" />}</div>
            <span className="scan-line" />
            <div className="reading-copy"><LoaderCircle className="spin" size={18} /><div><h3>Reading terminal output…</h3><p>Looking for a model and session identifier</p></div><b>{progress}%</b></div>
            <div className="progress-track"><span style={{ transform: `scaleX(${progress / 100})` }} /></div>
          </div>
        )}

        {stage === "review" && (
          <div className="review-layout">
            <div className="screenshot-column">
              <div className="preview-frame compact">{preview && <img src={preview} alt="Uploaded terminal screenshot" />}</div>
              <button type="button" className="replace-file" onClick={() => inputRef.current?.click()}><FileImage size={14} /> Replace screenshot</button>
              <input ref={inputRef} type="file" accept="image/png,image/jpeg,image/webp" onChange={onInput} hidden />
            </div>
            <div className="review-form">
              <div className={`detection-banner ${detected ? "success" : "needs-review"}`}>
                {detected ? <Check size={15} /> : <Clipboard size={15} />}
                <span>{detected ? "Resume command detected" : "Check the details manually"}</span>
                {detected && <b>Auto</b>}
              </div>
              {error && <p className="form-error inset">{error}</p>}
              <label>
                <span>Assistant</span>
                <select value={draft.model} onChange={(event) => { setDraft({ ...draft, model: event.target.value as Model }); setDetected(false); }}>
                  {MODELS.map((model) => <option key={model}>{model}</option>)}
                </select>
              </label>
              <label>
                <span>Resume command <b>Required</b></span>
                <div className="command-input"><span>$</span><input autoFocus value={draft.command} onChange={(event) => setDraft({ ...draft, command: event.target.value })} placeholder={MODEL_META[draft.model].hint + ' "session-id"'} /></div>
              </label>
              <label>
                <span>Project name</span>
                <input value={draft.project} onChange={(event) => setDraft({ ...draft, project: event.target.value })} placeholder="e.g. Billing portal" />
              </label>
              <label>
                <span>Project note <em>Optional</em></span>
                <textarea value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} placeholder="What were you working on?" rows={3} />
              </label>
            </div>
          </div>
        )}

        {stage === "review" && (
          <div className="dialog-footer">
            <span><span className="privacy-dot" /> Saved only on this device</span>
            <div><button type="button" className="secondary-button" onClick={close}>Cancel</button><button type="submit" className="primary-button" disabled={!draft.command.trim()}><Archive size={15} /> Save to library</button></div>
          </div>
        )}
      </form>
    </dialog>
  );
}

export default App;
