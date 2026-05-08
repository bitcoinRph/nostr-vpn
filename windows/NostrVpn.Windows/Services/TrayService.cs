using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using NostrVpn.Windows.Core;
using NostrVpn.Windows.ViewModels;

namespace NostrVpn.Windows.Services;

public sealed class TrayService : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
    private readonly Icon _normalIcon;
    private readonly Icon _blockedIcon;
    private AppViewModel? _viewModel;
    private Action? _showWindow;
    private Action? _quit;

    public TrayService()
    {
        _normalIcon = LoadIcon();
        _blockedIcon = CreateBlockedIcon(_normalIcon);
        _notifyIcon = new NotifyIcon
        {
            Icon = _normalIcon,
            Text = "Nostr VPN",
            Visible = true,
        };
        _notifyIcon.DoubleClick += (_, _) => _showWindow?.Invoke();
    }

    public void Attach(AppViewModel viewModel, Action showWindow, Action quit)
    {
        _viewModel = viewModel;
        _showWindow = showWindow;
        _quit = quit;
        viewModel.PropertyChanged += (_, _) => Update();
        Update();
    }

    public void Update()
    {
        if (_viewModel is null)
        {
            return;
        }

        _notifyIcon.Text = TruncateTrayText(TrayText(_viewModel));
        _notifyIcon.Icon = _viewModel.State.ExitNodeBlocked ? _blockedIcon : _normalIcon;
        _notifyIcon.ContextMenuStrip?.Dispose();
        _notifyIcon.ContextMenuStrip = BuildMenu(_viewModel);
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _normalIcon.Dispose();
        _blockedIcon.Dispose();
    }

    private ContextMenuStrip BuildMenu(AppViewModel viewModel)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add(Item("Open Nostr VPN", (_, _) => _showWindow?.Invoke()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item(TrayText(viewModel), (_, _) => { }, false));
        menu.Items.Add(Item(viewModel.State.VpnEnabled ? "Turn VPN Off" : "Turn VPN On", async (_, _) => await viewModel.ToggleVpnAsync(), viewModel.State.VpnControlSupported));
        menu.Items.Add(Item(viewModel.State.AdvertiseExitNode ? "Stop Offering Exit" : "Offer Private Exit", async (_, _) => await viewModel.SetAdvertiseExitNodeAsync(!viewModel.State.AdvertiseExitNode)));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("Copy This Device", (_, _) => viewModel.CopyText(viewModel.ThisDeviceCopyValue), !string.IsNullOrWhiteSpace(viewModel.ThisDeviceCopyValue)));

        var network = viewModel.ActiveNetwork;
        if (network is not null)
        {
            var devices = new ToolStripMenuItem(string.IsNullOrWhiteSpace(network.Name) ? "Network Devices" : network.Name);
            foreach (var participant in network.Participants)
            {
                devices.DropDownItems.Add(Item(ParticipantMenuTitle(participant), (_, _) => viewModel.CopyText(participant.Npub)));
            }
            menu.Items.Add(devices);

            var exitNodes = new ToolStripMenuItem("Exit Node");
            exitNodes.DropDownItems.Add(Item("No exit node", async (_, _) => await viewModel.SetExitNodeAsync("")));
            foreach (var participant in network.Participants.Where(participant => participant.OffersExitNode))
            {
                var item = Item(DeviceName(participant), async (_, _) => await viewModel.SetExitNodeAsync(participant.Npub));
                item.Checked = viewModel.State.ExitNode == participant.Npub;
                exitNodes.DropDownItems.Add(item);
            }
            menu.Items.Add(exitNodes);
        }

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("Refresh", async (_, _) => await viewModel.RefreshAsync()));
        menu.Items.Add(Item("Quit", (_, _) => _quit?.Invoke()));
        return menu;
    }

    private static ToolStripMenuItem Item(string text, EventHandler onClick, bool enabled = true)
    {
        var item = new ToolStripMenuItem(text) { Enabled = enabled };
        item.Click += onClick;
        return item;
    }

    private static Icon LoadIcon()
    {
        foreach (var filename in new[] { "nostr-vpn-tray.ico", "nostr-vpn.ico" })
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", filename);
            if (File.Exists(iconPath))
            {
                return new Icon(iconPath);
            }
        }

        return (Icon)SystemIcons.Application.Clone();
    }

    private static Icon CreateBlockedIcon(Icon baseIcon)
    {
        using var bitmap = baseIcon.ToBitmap();
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var diameter = Math.Max(6, Math.Min(bitmap.Width, bitmap.Height) / 3);
        var x = bitmap.Width - diameter - 1;
        var y = 1;
        using var brush = new SolidBrush(Color.FromArgb(220, 38, 38));
        graphics.FillEllipse(brush, x, y, diameter, diameter);
        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static string TrayText(AppViewModel viewModel)
    {
        var status = !string.IsNullOrWhiteSpace(viewModel.State.ExitNodeStatusText)
            ? viewModel.State.ExitNodeStatusText
            : viewModel.State.VpnStatus;
        return $"Nostr VPN - {status}";
    }

    private static string TruncateTrayText(string value)
    {
        return value.Length <= 63 ? value : value[..60] + "...";
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    private static string ParticipantMenuTitle(NativeParticipantState participant)
    {
        var name = DeviceName(participant);
        return string.IsNullOrWhiteSpace(participant.TunnelIp) || participant.TunnelIp == "-"
            ? name
            : $"{name} ({participant.TunnelIp})";
    }

    private static string DeviceName(NativeParticipantState participant)
    {
        if (!string.IsNullOrWhiteSpace(participant.MagicDnsName))
        {
            return participant.MagicDnsName;
        }
        if (!string.IsNullOrWhiteSpace(participant.Alias))
        {
            return participant.Alias;
        }
        return participant.Npub.Length > 16
            ? $"{participant.Npub[..10]}...{participant.Npub[^6..]}"
            : participant.Npub;
    }
}
