using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Auxilium
{
    // Panel bez treperenja (dvostruko međuspremanje) - koristi se za zaglavlje s logotipom.
    public class BufferedPanel : Panel
    {
        public BufferedPanel()
        {
            this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                          ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            this.UpdateStyles();
        }
    }

    // Kartica (GroupBox) u stilu Auxilium web aplikacije: puna ispuna + obrub od 1 px; naslov VELIKIM SLOVIMA unutar kartice.
    // Naslov se crta GDI+-om (DrawString) kako bi radio i s fontovima učitanima iz PrivateFontCollection (GDI/TextRenderer ih ne podržava).
    public class CardBox : GroupBox
    {
        private Color borderColor = Color.FromArgb(42, 53, 80);

        public Color BorderColor
        {
            get { return borderColor; }
            set { borderColor = value; this.Invalidate(); }
        }

        public CardBox()
        {
            this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                          ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            this.UpdateStyles();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.Clear(this.BackColor);
            using (Pen pen = new Pen(borderColor))
            {
                g.DrawRectangle(pen, 0, 0, this.Width - 1, this.Height - 1);
            }
            if (this.Text.Length > 0)
            {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
                using (StringFormat sf = new StringFormat(StringFormat.GenericTypographic))
                using (SolidBrush brush = new SolidBrush(this.ForeColor))
                {
                    sf.FormatFlags |= StringFormatFlags.NoWrap;
                    sf.Trimming = StringTrimming.EllipsisCharacter;
                    sf.HotkeyPrefix = System.Drawing.Text.HotkeyPrefix.None;
                    g.DrawString(this.Text.ToUpperInvariant(), this.Font, brush, new RectangleF(10, 5, Math.Max(10, this.Width - 20), this.Font.Height + 2), sf);
                }
            }
        }
    }

    // Plošni gumb: obrub 1 px, natpis VELIKIM SLOVIMA (Text ostaje izvorni), hover = jantarni obrub i tekst.
    // Vrste: 0 = običan, 1 = primarni (jantarna ispuna, tamni tekst), 2 = opasnost / prekid (crveni obrub, bez ispune).
    // Boje postavlja PowerShell iz zajedničke palete. Crta se GDI+-om (radi i s privatnim fontovima), s tekstom isključivo u jednom retku.
    public class SkinButton : Button
    {
        public int Kind = 0;
        public Color ColorBack = Color.FromArgb(22, 31, 48);
        public Color ColorPressed = Color.FromArgb(17, 24, 38);
        public Color ColorLine = Color.FromArgb(42, 53, 80);
        public Color ColorText = Color.FromArgb(232, 236, 245);
        public Color ColorAccent = Color.FromArgb(255, 201, 74);
        public Color ColorAccentDim = Color.FromArgb(201, 154, 58);
        public Color ColorOnAccent = Color.FromArgb(19, 19, 19);
        public Color ColorDanger = Color.FromArgb(255, 75, 75);
        public Color ColorPage = Color.FromArgb(9, 12, 20);
        public Color ColorDisabled = Color.FromArgb(93, 100, 120);
        public Color ColorFocus = Color.FromArgb(95, 216, 201);
        private bool hot;
        private bool down;

        public SkinButton()
        {
            this.SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                          ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                          ControlStyles.Selectable, true);
            this.UpdateStyles();
            this.UseVisualStyleBackColor = false;
            this.TabStop = true;
        }

        protected override void OnMouseEnter(EventArgs e) { hot = true; this.Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; this.Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { down = true; this.Invalidate(); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; this.Invalidate(); base.OnMouseUp(e); }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            // Dok je tipka miša pritisnuta WinForms ne šalje MouseLeave: izvan gumba se vraća uobičajeni izgled (klik se tada ionako ne izvršava).
            if (this.Capture && (Control.MouseButtons & MouseButtons.Left) != 0)
            {
                bool inside = this.ClientRectangle.Contains(e.Location);
                if (down != inside || hot != inside) { down = inside; hot = inside; this.Invalidate(); }
            }
            base.OnMouseMove(e);
        }
        protected override void OnEnabledChanged(EventArgs e) { hot = false; down = false; this.Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnGotFocus(EventArgs e) { this.Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { down = false; this.Invalidate(); base.OnLostFocus(e); }
        protected override void OnTextChanged(EventArgs e) { this.Invalidate(); base.OnTextChanged(e); }
        protected override void OnPaintBackground(PaintEventArgs pevent) { }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Color parentBack = (this.Parent != null) ? this.Parent.BackColor : ColorPage;
            Color back; Color line; Color text;
            if (!this.Enabled)
            {
                back = (Kind == 2) ? parentBack : ColorBack; line = ColorLine; text = ColorDisabled;
            }
            else if (Kind == 1)
            {
                back = (hot || down) ? ColorAccentDim : ColorAccent; line = back; text = ColorOnAccent;
            }
            else if (Kind == 2)
            {
                back = (hot || down) ? ColorDanger : parentBack; line = ColorDanger; text = (hot || down) ? ColorPage : ColorDanger;
            }
            else
            {
                back = down ? ColorPressed : ColorBack; line = hot ? ColorAccent : ColorLine; text = hot ? ColorAccent : ColorText;
            }
            if (this.Enabled && this.Focused && this.ShowFocusCues && !hot) { line = ColorFocus; }

            using (SolidBrush fill = new SolidBrush(back)) { g.FillRectangle(fill, 0, 0, this.Width, this.Height); }
            using (Pen pen = new Pen(line)) { g.DrawRectangle(pen, 0, 0, this.Width - 1, this.Height - 1); }

            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            using (StringFormat sf = new StringFormat())
            using (SolidBrush brush = new SolidBrush(text))
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                sf.FormatFlags = StringFormatFlags.NoWrap;
                sf.Trimming = StringTrimming.EllipsisCharacter;
                sf.HotkeyPrefix = System.Drawing.Text.HotkeyPrefix.None;
                RectangleF rect = new RectangleF(4, 1, Math.Max(1, this.Width - 8), Math.Max(1, this.Height - 2));
                string label = (this.Text ?? "").ToUpperInvariant();
                Font drawFont = this.Font;
                Font shrunk = null;
                try
                {
                    // Predugačak natpis smanjuje se u koracima od 0,5 pt (najmanje 7 pt) umjesto da se odreže elipsom.
                    float size = this.Font.SizeInPoints;
                    while (size > 7f && g.MeasureString(label, drawFont, 100000, sf).Width > rect.Width)
                    {
                        size -= 0.5f;
                        if (shrunk != null) { shrunk.Dispose(); }
                        shrunk = new Font(this.Font.FontFamily, size, this.Font.Style, GraphicsUnit.Point);
                        drawFont = shrunk;
                    }
                    g.DrawString(label, drawFont, brush, rect, sf);
                }
                finally
                {
                    if (shrunk != null) { shrunk.Dispose(); }
                }
            }
        }
    }
    // Padajući popis (DropDown) s tamnim gumbom sa strelicom: nakon standardnog crtanja gumb se preslikava bojama palete.
    // Okvir od 1 px crta roditeljski panel (u fokusu tirkizan), pa ovdje ostaje samo gumb.
    public class SkinCombo : ComboBox
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        private struct COMBOBOXINFO
        {
            public int cbSize;
            public RECT rcItem;
            public RECT rcButton;
            public int stateButton;
            public IntPtr hwndCombo;
            public IntPtr hwndItem;
            public IntPtr hwndList;
        }

        [DllImport("user32.dll")]
        private static extern bool GetComboBoxInfo(IntPtr hwnd, ref COMBOBOXINFO info);

        public Color ColorButton = Color.FromArgb(22, 31, 48);
        public Color ColorLine = Color.FromArgb(42, 53, 80);
        public Color ColorArrow = Color.FromArgb(139, 147, 169);
        public Color ColorArrowOpen = Color.FromArgb(255, 201, 74);

        protected override void WndProc(ref Message m)
        {
            base.WndProc(ref m);
            if (m.Msg == 0x000F && this.IsHandleCreated) { PaintButton(); }
        }

        private void PaintButton()
        {
            try
            {
                COMBOBOXINFO info = new COMBOBOXINFO();
                info.cbSize = Marshal.SizeOf(typeof(COMBOBOXINFO));
                if (!GetComboBoxInfo(this.Handle, ref info)) { return; }
                Rectangle r = Rectangle.FromLTRB(info.rcButton.Left, info.rcButton.Top, info.rcButton.Right, info.rcButton.Bottom);
                if (r.Width <= 0 || r.Height <= 0) { return; }
                using (Graphics g = Graphics.FromHwnd(this.Handle))
                {
                    // Flat ComboBox sam crta vanjski rub bijelom bojom (SystemColors.Window) i bijeli razdjelnik lijevo od gumba: prebojava se bojom polja,
                    // a okvir od 1 px (Line, u fokusu tirkizan) crta roditeljski panel.
                    Rectangle cr = this.ClientRectangle;
                    using (SolidBrush pageFill = new SolidBrush(this.BackColor))
                    {
                        g.FillRectangle(pageFill, 0, 0, cr.Width, 1);
                        g.FillRectangle(pageFill, 0, cr.Height - 1, cr.Width, 1);
                        g.FillRectangle(pageFill, 0, 0, 1, cr.Height);
                        g.FillRectangle(pageFill, Math.Max(0, r.Left - 2), 1, 2, Math.Max(1, cr.Height - 2));
                    }
                    Rectangle full = new Rectangle(r.Left, 0, Math.Max(1, cr.Width - r.Left), cr.Height);
                    using (SolidBrush fill = new SolidBrush(ColorButton)) { g.FillRectangle(fill, full); }
                    using (Pen line = new Pen(ColorLine)) { g.DrawLine(line, r.Left, 0, r.Left, cr.Height - 1); }
                    g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    int cx = r.Left + r.Width / 2 + 1;
                    int cy = r.Top + r.Height / 2;
                    using (Pen arrow = new Pen(this.DroppedDown ? ColorArrowOpen : ColorArrow, 1.6f))
                    {
                        g.DrawLines(arrow, new Point[] { new Point(cx - 4, cy - 2), new Point(cx, cy + 2), new Point(cx + 4, cy - 2) });
                    }
                }
            }
            catch { }
        }
    }

    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SHQUERYRBINFO
        {
            public int cbSize;
            public long i64Size;
            public long i64NumItems;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr handle);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        // Očuvanje položaja skrolanja RichTextBoxa pri ponovnom crtanju (EM_GETFIRSTVISIBLELINE / EM_LINESCROLL).
        public static int GetFirstVisibleLine(IntPtr handle)
        {
            try { return (int)SendMessage(handle, 0xCE, IntPtr.Zero, IntPtr.Zero); } catch { return 0; }
        }

        public static void ScrollToFirstVisibleLine(IntPtr handle, int line)
        {
            try
            {
                int current = (int)SendMessage(handle, 0xCE, IntPtr.Zero, IntPtr.Zero);
                SendMessage(handle, 0xB6, IntPtr.Zero, (IntPtr)(line - current));
            }
            catch { }
        }

        [DllImport("kernel32.dll")]
        public static extern uint GetOEMCP();

        // Tamna naslovna traka (Windows 10 2004+ / Windows 11); na starijim sustavima se tiho ignorira.
        public static void TryEnableDarkTitleBar(IntPtr handle)
        {
            try
            {
                int on = 1;
                if (DwmSetWindowAttribute(handle, 20, ref on, 4) != 0) { DwmSetWindowAttribute(handle, 19, ref on, 4); }
            }
            catch { }
        }

        public static int QueryRecycleBin(out long size, out long items)
        {
            SHQUERYRBINFO info = new SHQUERYRBINFO();
            info.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
            int hr = SHQueryRecycleBin(null, ref info);
            size = info.i64Size;
            items = info.i64NumItems;
            return hr;
        }

        // SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND.
        // Pražnjenje je sinkrono i može trajati; izvodi se na zasebnoj STA niti kako sučelje ne bi zamrznulo.
        public static System.Threading.Tasks.Task<int> EmptyRecycleBinAsync()
        {
            System.Threading.Tasks.TaskCompletionSource<int> tcs = new System.Threading.Tasks.TaskCompletionSource<int>();
            System.Threading.Thread worker = new System.Threading.Thread(delegate ()
            {
                try { tcs.SetResult(SHEmptyRecycleBin(IntPtr.Zero, null, 0x7)); }
                catch (Exception ex) { tcs.SetException(ex); }
            });
            worker.SetApartmentState(System.Threading.ApartmentState.STA);
            worker.IsBackground = true;
            worker.Start();
            return tcs.Task;
        }

        public static void TrySetDarkScrollbars(IntPtr handle)
        {
            try { SetWindowTheme(handle, "DarkMode_Explorer", null); } catch { }
        }

        public static void TrySetTheme(IntPtr handle, string theme)
        {
            try { SetWindowTheme(handle, theme, null); } catch { }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME64 { public uint Low; public uint High; }

        [DllImport("kernel32.dll")]
        private static extern bool GetSystemTimes(out FILETIME64 idle, out FILETIME64 kernel, out FILETIME64 user);

        // Vrijeme procesora (mirovanje i ukupno, jedinice od 100 ns): opterećenje = 1 - razlika(mirovanje) / razlika(ukupno) između dva očitanja.
        // Ne ovisi o jeziku Windowsa (za razliku od brojača performansi s lokaliziranim nazivima).
        public static bool GetCpuTimes(out ulong idle, out ulong total)
        {
            idle = 0; total = 0;
            try
            {
                FILETIME64 i, k, u;
                if (!GetSystemTimes(out i, out k, out u)) { return false; }
                idle = ((ulong)i.High << 32) | i.Low;
                total = (((ulong)k.High << 32) | k.Low) + (((ulong)u.High << 32) | u.Low);
                return true;
            }
            catch { return false; }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);

        // Postotak zauzete fizičke memorije; -1 ako očitanje nije uspjelo.
        public static int GetMemoryLoad()
        {
            try
            {
                MEMORYSTATUSEX s = new MEMORYSTATUSEX();
                if (GlobalMemoryStatusEx(s)) { return (int)s.dwMemoryLoad; }
            }
            catch { }
            return -1;
        }

        // Korisnik prijavljen u konzolnu sesiju (DOMENA\korisnik) bez WMI-ja; "" = nitko nije prijavljen, null = poziv nije uspio.
        [DllImport("kernel32.dll")]
        private static extern uint WTSGetActiveConsoleSessionId();

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WTSQuerySessionInformationW(IntPtr hServer, uint sessionId, int wtsInfoClass, out IntPtr ppBuffer, out int pBytesReturned);

        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr pMemory);

        private static string QueryWtsString(uint sessionId, int infoClass)
        {
            IntPtr buffer = IntPtr.Zero;
            int bytes;
            if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, infoClass, out buffer, out bytes) || buffer == IntPtr.Zero) { return null; }
            try { return Marshal.PtrToStringUni(buffer); }
            finally { WTSFreeMemory(buffer); }
        }

        public static string GetConsoleUserName()
        {
            try
            {
                uint session = WTSGetActiveConsoleSessionId();
                if (session == 0xFFFFFFFF) { return ""; }
                string user = QueryWtsString(session, 5);    // WTSUserName
                if (user == null) { return null; }
                if (user.Length == 0) { return ""; }
                string domain = QueryWtsString(session, 7);  // WTSDomainName
                if (string.IsNullOrEmpty(domain)) { return user; }
                return domain + "\\" + user;
            }
            catch { return null; }
        }

        public static void TryDestroyIcon(IntPtr handle)
        {
            try { DestroyIcon(handle); } catch { }
        }
    }
}
