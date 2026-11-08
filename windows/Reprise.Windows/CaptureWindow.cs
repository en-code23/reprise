using Reprise.Core;

namespace Reprise.Windows;

internal sealed class CaptureWindow : Form
{
    private readonly Session original;
    private readonly ComboBox model = Theme.Combo(["codex", "claude", "grok", "other"]);
    private readonly ComboBox source = Theme.Combo(["Automatic", .. NativeServices.Origins]);
    private readonly TextBox project = new(), directory = new(), command = new(), note = new();
    private readonly Label status = Theme.Label("Screenshots are read on this PC. Review the command before saving.");
    private readonly Button save;
    internal Session? Result { get; private set; }

    internal CaptureWindow(Session? editing = null)
    {
        original = editing is null ? new Session() : editing with { };
        Text = editing == null ? "Add session — Reprise" : "Session details — Reprise";
        Font = new Font("Segoe UI", 10); BackColor = Theme.Paper; ForeColor = Theme.Ink;
        Icon = NativeServices.LoadIcon(); StartPosition = FormStartPosition.CenterParent; MinimumSize = new Size(620, 650); Size = new Size(680, 730);
        AllowDrop = true;
        DragEnter += (_, e) => e.Effect = e.Data?.GetDataPresent(DataFormats.FileDrop) == true ? DragDropEffects.Copy : DragDropEffects.None;
        DragDrop += async (_, e) => { if (e.Data?.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) await ReadImage(files[0]); };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 2, RowCount = 9 };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130)); layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(layout);
        var screenshot = Theme.Button("Choose screenshot…", async (_, _) => { using var picker = new OpenFileDialog { Filter = "Screenshots|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff", Title = "Choose a terminal screenshot" }; if (picker.ShowDialog(this) == DialogResult.OK) await ReadImage(picker.FileName); });
        layout.Controls.Add(screenshot, 0, 0); layout.SetColumnSpan(screenshot, 2);
        status.Dock = DockStyle.Fill; layout.Controls.Add(status, 0, 1); layout.SetColumnSpan(status, 2);
        AddField(layout, 2, "Assistant", model); AddField(layout, 3, "Project", project);
        var folder = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoSize = false, Margin = new Padding(0) };
        folder.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); folder.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 95));
        directory.Dock = DockStyle.Fill;
        var choose = Theme.Button("Choose…", (_, _) => { using var picker = new FolderBrowserDialog { Description = "Choose the project folder", UseDescriptionForTitle = true }; if (picker.ShowDialog(this) == DialogResult.OK) { directory.Text = picker.SelectedPath; if (string.IsNullOrWhiteSpace(project.Text)) project.Text = ProjectPaths.Name(picker.SelectedPath); } });
        choose.AutoSize = false; choose.MinimumSize = new Size(85, 32); choose.Margin = new Padding(8, 0, 0, 6); choose.Dock = DockStyle.Fill;
        folder.Controls.Add(directory, 0, 0); folder.Controls.Add(choose, 1, 0); AddField(layout, 4, "Project folder", folder);
        command.Font = new Font("Consolas", 10); AddField(layout, 5, "Resume command", command);
        AddField(layout, 6, "Session source", source);
        note.Multiline = true; note.AcceptsReturn = true; note.ScrollBars = ScrollBars.Vertical; note.MinimumSize = new Size(0, 100); AddField(layout, 7, "Project note", note);
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        for (var i = 2; i < 7; i++) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 52));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var actions = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, AutoSize = true, WrapContents = true };
        save = Theme.Button("Save session", (_, _) => SaveSession(), true);
        var cancel = Theme.Button("Cancel", (_, _) => { DialogResult = DialogResult.Cancel; Close(); });
        actions.Controls.Add(save); actions.Controls.Add(cancel); CancelButton = cancel;
        layout.Controls.Add(actions, 0, 8); layout.SetColumnSpan(actions, 2);
        project.Text = original.Project; directory.Text = original.ProjectDirectory ?? ""; command.Text = original.Command; note.Text = original.Note;
        model.SelectedItem = original.Model; source.SelectedItem = original.OriginOverride ?? "Automatic";
        AcceptButton = save;
    }
    private static void AddField(TableLayoutPanel layout, int row, string title, Control control)
    {
        var label = Theme.Label(title); label.Padding = new Padding(0, 6, 0, 0); layout.Controls.Add(label, 0, row);
        control.Dock = DockStyle.Fill; control.Margin = new Padding(0, 0, 0, 12); layout.Controls.Add(control, 1, row);
    }
    internal async Task ReadImage(string path)
    {
        save.Enabled = false; status.Text = "Reading screenshot locally…";
        try
        {
            var text = await NativeServices.ReadScreenshot(path);
            if (IsDisposed) return;
            var parsed = Commands.Parse(text);
            model.SelectedItem = parsed.Model; command.Text = parsed.Command;
            directory.Text = parsed.Directory ?? directory.Text;
            if (string.IsNullOrWhiteSpace(project.Text)) project.Text = parsed.Directory == null ? Path.GetFileNameWithoutExtension(path) : ProjectPaths.Name(parsed.Directory);
            original.SourceFileName = Path.GetFileName(path);
            status.Text = string.IsNullOrEmpty(parsed.Command) ? "No resume command found. Enter it manually below." : "Command found. Check the session ID and project folder before saving.";
        }
        catch (Exception error) { if (!IsDisposed) status.Text = "The image could not be read. You can enter the command manually. " + error.Message; }
        finally { if (!IsDisposed) save.Enabled = true; }
    }
    private void SaveSession()
    {
        if (string.IsNullOrWhiteSpace(project.Text) || string.IsNullOrWhiteSpace(command.Text)) { MessageBox.Show(this, "Enter a project name and resume command.", "Check the details"); return; }
        Result = original with { Model = model.SelectedItem?.ToString() ?? "other", Project = project.Text.Trim(), ProjectDirectory = string.IsNullOrWhiteSpace(directory.Text) ? null : directory.Text.Trim(), Command = Commands.Canonicalize(command.Text), Note = note.Text,
            OriginOverride = source.SelectedItem?.ToString() == "Automatic" ? null : source.SelectedItem?.ToString() };
        DialogResult = DialogResult.OK; Close();
    }
}
