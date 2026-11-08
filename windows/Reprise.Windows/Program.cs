using System.Runtime.InteropServices;
using Reprise.Core;
using Velopack;

namespace Reprise.Windows;

internal static class Program
{
    internal static readonly uint ShowLibraryMessage = RegisterWindowMessage("Reprise.ShowLibrary.8427F045-8F92-43D3-9A9A-41C8AF33D874");
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);

    [STAThread]
    private static void Main(string[] args)
    {
        VelopackApp.Build().Run();
        ApplicationConfiguration.Initialize();
        if (args.Length == 2 && args[0] == "--smoke-test")
        {
            try { UiSmoke.Run(args[1]); }
            catch (Exception error)
            {
                Directory.CreateDirectory(args[1]); File.WriteAllText(Path.Combine(args[1], "error.txt"), error.ToString()); Environment.ExitCode = 1;
            }
            return;
        }
        using var mutex = new Mutex(true, "Local\\Reprise.SessionLibrary.8427F045", out var primary);
        if (!primary) { PostMessage((nint)0xffff, ShowLibraryMessage, 0, 0); return; }
        try
        {
            // Keep user data outside Velopack's per-user Reprise install folder.
            var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RepriseLibrary");
            var store = new SessionStore(directory);
            Application.Run(new LibraryWindow(store));
        }
        catch (Exception error) { MessageBox.Show(error.Message, "Reprise could not start", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
