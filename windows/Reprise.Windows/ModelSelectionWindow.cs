using Reprise.Core;

namespace Reprise.Windows;

internal sealed class ModelSelectionWindow : Form
{
    private readonly ModelSelectionStore routing;
    private readonly FlowLayoutPanel content = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(24) };
    private readonly FlowLayoutPanel usage = new() { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Width = 570 };
    private readonly ComboBox provider = Theme.Combo(ModelSelectionStore.Providers);
    private readonly Button refresh;
    private bool binding;

    internal ModelSelectionWindow(ModelSelectionStore routing)
    {
        this.routing = routing;
        Text = "Automatic model selection"; Icon = NativeServices.LoadIcon(); Font = new Font("Segoe UI", 10);
        BackColor = Color.White; ClientSize = new Size(650, 710); MinimumSize = new Size(650, 560); StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi; Controls.Add(content);
        Add(Theme.Label("Automatic model selection", 19, true));
        Add(Theme.Label("Choose models within each session’s provider. Managed sessions reassess the task and switch between completed turns. Project analysis stays on this PC.", 10));
        Toggle("Enable automatic selection", routing.Preferences.Enabled, value => routing.Preferences.Enabled = value);
        Toggle("Switch between turns in managed sessions", routing.Preferences.Continuous, value => routing.Preferences.Continuous = value);
        Toggle("Use more capability when a reset is near", routing.Preferences.UseExpiringHeadroom, value => routing.Preferences.UseExpiringHeadroom = value);
        var reserve = new NumericUpDown { Minimum = 5, Maximum = 50, Increment = 5, Value = (decimal)Math.Clamp(routing.Preferences.ReservePercent, 5, 50), Width = 80 };
        reserve.ValueChanged += (_, _) => { routing.Preferences.ReservePercent = (double)reserve.Value; routing.Save(); };
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Width = 570 };
        row.Controls.Add(Theme.Label("Conserve below % remaining", 10)); row.Controls.Add(reserve); Add(row);
        Add(Theme.Label("Usage and reset times", 12, true));
        var controls = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Width = 570 };
        provider.Width = 150; controls.Controls.Add(provider);
        refresh = Theme.Button("Refresh", async (_, _) => await RefreshUsage()); controls.Controls.Add(refresh);
        Add(controls); Add(usage);
        provider.SelectedIndexChanged += (_, _) => BindUsage();
        Add(Theme.Label("Use the session’s … menu to choose a work type or turn off selection for one project. During a managed session, use /usage, /work, /model, or /auto off.", 9));
        var advanced = new CheckBox { Text = "Advanced options", AutoSize = true };
        var options = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Width = 570, Visible = false };
        advanced.CheckedChanged += (_, _) => options.Visible = advanced.Checked; Add(advanced); Add(options);
        var max = new CheckBox { Text = "Allow max only for large, early backend foundations", AutoSize = true, Checked = routing.Preferences.AllowFoundationMax };
        max.CheckedChanged += (_, _) => { routing.Preferences.AllowFoundationMax = max.Checked; routing.Save(); }; options.Controls.Add(max);
        options.Controls.Add(Theme.Label("Normally capped at high. Max also needs at least 75% shared allowance; reset timing alone never enables it. Selections estimate suitability and usage, rather than predicting an exact cost.", 9));
        if (routing.Error != null) Add(Theme.Label(routing.Error, 9));
        var done = Theme.Button("Done", (_, _) => Close()); Add(done); AcceptButton = done;
        BindUsage();
    }
    private void Add(Control control) { control.MaximumSize = new Size(570, 0); content.Controls.Add(control); }
    private void Toggle(string text, bool value, Action<bool> set)
    {
        var check = new CheckBox { Text = text, AutoSize = true, Checked = value, Margin = new Padding(0, 0, 0, 10) };
        check.CheckedChanged += (_, _) => { set(check.Checked); routing.Save(); BindUsage(); }; Add(check);
    }
    private async Task RefreshUsage()
    {
        if (!routing.Preferences.Enabled) return;
        refresh.Enabled = false;
        try { if (provider.Text == "claude") { routing.ClaudeConnected = true; routing.Save(); } await routing.Refresh(provider.Text); }
        finally { if (!IsDisposed) { refresh.Enabled = true; BindUsage(); } }
    }
    private void BindUsage()
    {
        if (binding) return; binding = true;
        try {
            routing.ReadCaches(); usage.SuspendLayout(); usage.Controls.Clear();
            var state = routing.State(provider.Text);
            refresh.Enabled = routing.Preferences.Enabled;
            refresh.Text = provider.Text == "claude" && !routing.ClaudeConnected ? "Connect Claude usage…" : "Refresh";
            usage.Controls.Add(Theme.Label(state?.Status ?? "Refresh to read this CLI’s available models and usage windows.", 9));
            if (provider.Text == "claude") usage.Controls.Add(Theme.Label("Uses Claude Code’s existing subscription login. Only usage percentages and reset times are saved. This usage connection may need updating when Claude changes its endpoint.", 9));
            if (state != null) foreach (var window in state.Windows) {
                var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                var reset = window.ResetsAt > now && window.ResetsAt < 253402300799 ? DateTimeOffset.FromUnixTimeSeconds((long)window.ResetsAt).ToLocalTime().ToString("g") : "refresh required";
                usage.Controls.Add(Theme.Label($"{window.Label}: {Math.Clamp(100 - window.UsedPercent, 0, 100):0}% left · resets {reset}" + (window.Fresh(now) ? "" : " · stale"), 10));
            }
            if (provider.Text == "claude") {
                var fable = new CheckBox { Text = "Allow Fable when its included allowance has room", AutoSize = true, Checked = routing.Preferences.UseFableAllowance };
                fable.CheckedChanged += (_, _) => { routing.Preferences.UseFableAllowance = fable.Checked; routing.Save(); }; usage.Controls.Add(fable);
                usage.Controls.Add(Theme.Label("Needs confirmed shared weekly and separate Fable capacity. Reprise never redeems reset credits. For unnamed allowances, match the field to Claude’s Usage screen before selecting it below, then refresh.", 9));
                var keys = state?.Windows.Where(w => w.Id.StartsWith("seven_day_")).Select(w => w.Id).ToArray() ?? [];
                if (keys.Length > 0) {
                    var mapping = Theme.Combo(["Automatic · named Fable field only", .. keys]); mapping.Width = 420;
                    mapping.SelectedIndex = Array.IndexOf(keys, routing.FableWindowId) + 1;
                    mapping.SelectedIndexChanged += (_, _) => { routing.FableWindowId = mapping.SelectedIndex > 0 ? mapping.Text : ""; routing.Save(); }; usage.Controls.Add(mapping);
                }
            }
            if (state != null && state.Models.Count > 0) {
                var roles = new CheckBox { Text = "Model roles", AutoSize = true }; usage.Controls.Add(roles);
                var rows = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Visible = false, Width = 570 };
                roles.CheckedChanged += (_, _) => rows.Visible = roles.Checked; usage.Controls.Add(rows);
                foreach (var model in state.Models.Where(m => m.Valid)) {
                    var line = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Width = 570 };
                    var label = Theme.Label(model.Name, 9); label.AutoSize = false; label.Size = new Size(300, 30); line.Controls.Add(label);
                    var role = Theme.Combo(["Economy", "Everyday", "Strong", "Architecture"]); role.SelectedIndex = model.Role;
                    role.SelectedIndexChanged += (_, _) => { model.Role = role.SelectedIndex; routing.Preferences.ModelRoles[$"{state.Provider}:{model.Id}"] = model.Role; routing.Save(); }; line.Controls.Add(role); rows.Controls.Add(line);
                }
            }
        } finally { usage.ResumeLayout(true); binding = false; }
    }
}
