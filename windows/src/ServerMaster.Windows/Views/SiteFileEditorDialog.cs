using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using ContentDialog = ServerMaster.Windows.Views.LocalizedContentDialog;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI;
using ServerMaster.Windows.Models;
using ServerMaster.Windows.Services;
using Windows.System;
using Microsoft.UI.Text;

namespace ServerMaster.Windows.Views;

public sealed class SiteFileEditorDialog : ContentDialog
{
    public SiteFileEditorDialog(FileEntry entry, SiteTextDocument document)
    {
        Title = entry.Name;
        PrimaryButtonText = "Save";
        SecondaryButtonText = "Revert";
        CloseButtonText = "Close";
        DefaultButton = ContentDialogButton.None;
        Resources["ContentDialogMaxWidth"] = 900d;
        var body = new Grid { Width = 760, RowSpacing = 10 };
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var path = new TextBlock { Text = entry.FullPath, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        body.Children.Add(path);
        var toolbar = new Grid { ColumnSpacing = 8 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < 4; i++) toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var search = new TextBox { PlaceholderText = "Find" };
        var find = new Button { Content = new SymbolIcon(Symbol.Find) };
        ToolTipService.SetToolTip(find, "Find next");
        var wrap = new ToggleButton { Content = "Wrap" };
        var replaceToggle = new ToggleButton { Content = new SymbolIcon(Symbol.Edit) };
        ToolTipService.SetToolTip(replaceToggle, "Find and replace");
        var state = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        // Icon-only buttons need a spoken name; the tooltip alone is not announced as one.
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(find, Localization.T("Find next"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(replaceToggle, Localization.T("Find and replace"));
        toolbar.Children.Add(search);
        Grid.SetColumn(find, 1); toolbar.Children.Add(find);
        Grid.SetColumn(wrap, 2); toolbar.Children.Add(wrap);
        Grid.SetColumn(replaceToggle, 3); toolbar.Children.Add(replaceToggle);
        Grid.SetColumn(state, 4); toolbar.Children.Add(state);
        Grid.SetRow(toolbar, 1); body.Children.Add(toolbar);
        var replaceRow = new Grid { ColumnSpacing = 8, Visibility = Visibility.Collapsed };
        replaceRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        replaceRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        replaceRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var replacement = new TextBox { PlaceholderText = "Replace with" };
        var replace = new Button { Content = "Replace" };
        var replaceAll = new Button { Content = "Replace all" };
        replaceRow.Children.Add(replacement);
        Grid.SetColumn(replace, 1); replaceRow.Children.Add(replace);
        Grid.SetColumn(replaceAll, 2); replaceRow.Children.Add(replaceAll);
        Grid.SetRow(replaceRow, 2); body.Children.Add(replaceRow);
        var editorGrid = new Grid();
        editorGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
        editorGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var lineScroller = new ScrollViewer
        {
            HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            IsHitTestVisible = false, Background = new SolidColorBrush(ColorHelper.FromArgb(24, 128, 128, 128))
        };
        var lineNumbers = new TextBlock
        {
            FontFamily = new FontFamily("Consolas"), FontSize = 13, TextAlignment = TextAlignment.Right,
            Foreground = new SolidColorBrush(ColorHelper.FromArgb(180, 140, 145, 155)), Padding = new Thickness(0, 7, 8, 7)
        };
        lineScroller.Content = lineNumbers;
        editorGrid.Children.Add(lineScroller);
        var editor = new RichEditBox
        {
            AcceptsReturn = true, FontFamily = new FontFamily("Consolas"),
            FontSize = 13, TextWrapping = TextWrapping.NoWrap, IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false, MinHeight = 100, VerticalAlignment = VerticalAlignment.Stretch
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(editor, entry.Name);
        editor.Document.SetText(TextSetOptions.None, document.Text);
        ScrollViewer.SetHorizontalScrollBarVisibility(editor, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(editor, ScrollBarVisibility.Auto);
        Grid.SetColumn(editor, 1); editorGrid.Children.Add(editor);
        Grid.SetRow(editorGrid, 3); body.Children.Add(editorGrid);
        var discard = new Button { Content = "Discard changes" };
        var problem = new InfoBar { IsOpen = false, Severity = InfoBarSeverity.Error, IsClosable = true };
        Grid.SetRow(problem, 4); body.Children.Add(problem);
        Content = body;
        var allowDiscard = false;
        var saving = false;
        var formatting = false;
        var syntax = FileSyntax.ForFile(entry.Name);
        string EditorText()
        {
            editor.Document.GetText(TextGetOptions.None, out var value);
            return SiteFiles.FromRichEditText(value);
        }
        void SetEditorText(string value)
        {
            editor.Document.SetText(TextSetOptions.None, value);
            editor.Document.Selection.SetRange(0, 0);
        }
        bool HasChanges() => EditorText().ReplaceLineEndings("\n") != document.Text.ReplaceLineEndings("\n");
        void UpdateLineNumbers()
        {
            var count = Math.Max(1, EditorText().ReplaceLineEndings("\n").Count(character => character == '\n') + 1);
            lineNumbers.Text = string.Join(Environment.NewLine, Enumerable.Range(1, count));
        }
        void Highlight()
        {
            var text = EditorText();
            var selection = editor.Document.Selection;
            var start = selection.StartPosition;
            var end = selection.EndPosition;
            formatting = true;
            var whole = editor.Document.GetRange(0, text.Length);
            whole.CharacterFormat.ForegroundColor = ActualTheme == ElementTheme.Light ? Colors.Black : Colors.White;
            foreach (var span in syntax.Highlight(text))
            {
                var range = editor.Document.GetRange(span.Start, span.Start + span.Length);
                range.CharacterFormat.ForegroundColor = span.Kind switch
                {
                    FileSyntaxKind.Keyword => Colors.MediumPurple,
                    FileSyntaxKind.Number => Colors.DodgerBlue,
                    FileSyntaxKind.String => Colors.IndianRed,
                    _ => Colors.SeaGreen
                };
            }
            selection.SetRange(Math.Min(start, text.Length), Math.Min(end, text.Length));
            formatting = false;
        }
        var highlightTimer = DispatcherQueue.CreateTimer();
        highlightTimer.Interval = TimeSpan.FromMilliseconds(250);
        highlightTimer.IsRepeating = false;
        highlightTimer.Tick += (_, _) => Highlight();
        void Update()
        {
            var changed = HasChanges();
            IsPrimaryButtonEnabled = IsSecondaryButtonEnabled = !saving && changed;
            replace.IsEnabled = replaceAll.IsEnabled = !saving && search.Text.Length > 0;
            state.Text = saving ? "Saving..." : changed ? "edited" : document.EncodingName;
        }
        editor.TextChanged += (_, _) =>
        {
            if (formatting) return;
            UpdateLineNumbers();
            highlightTimer.Stop(); highlightTimer.Start();
            Update();
        };
        search.TextChanged += (_, _) => Update();
        replaceToggle.Checked += (_, _) => replaceRow.Visibility = Visibility.Visible;
        replaceToggle.Unchecked += (_, _) => replaceRow.Visibility = Visibility.Collapsed;
        wrap.Checked += (_, _) => editor.TextWrapping = TextWrapping.Wrap;
        wrap.Unchecked += (_, _) => editor.TextWrapping = TextWrapping.NoWrap;
        void Find(bool backwards = false)
        {
            if (search.Text.Length == 0) return;
            var text = EditorText();
            var selection = editor.Document.Selection;
            var index = backwards
                ? selection.StartPosition > 0 ? text.LastIndexOf(search.Text, selection.StartPosition - 1, StringComparison.OrdinalIgnoreCase) : -1
                : text.IndexOf(search.Text, Math.Min(text.Length, selection.EndPosition), StringComparison.OrdinalIgnoreCase);
            if (index < 0) index = backwards ? text.LastIndexOf(search.Text, StringComparison.OrdinalIgnoreCase) : text.IndexOf(search.Text, StringComparison.OrdinalIgnoreCase);
            if (index >= 0) { editor.Focus(FocusState.Programmatic); selection.SetRange(index, index + search.Text.Length); problem.IsOpen = false; }
            else { problem.Message = "No matches."; problem.ActionButton = null; problem.IsOpen = true; }
        }
        find.Click += (_, _) => Find();
        replace.Click += (_, _) =>
        {
            if (saving || search.Text.Length == 0) return;
            var selection = editor.Document.Selection;
            selection.GetText(TextGetOptions.None, out var selected);
            if (!selected.Equals(search.Text, StringComparison.OrdinalIgnoreCase)) { Find(); return; }
            var start = selection.StartPosition;
            selection.SetText(TextSetOptions.None, replacement.Text);
            selection.SetRange(start + replacement.Text.Length, start + replacement.Text.Length);
            Find();
        };
        replaceAll.Click += (_, _) =>
        {
            if (saving || search.Text.Length == 0) return;
            var current = EditorText();
            var updated = current.Replace(search.Text, replacement.Text, StringComparison.OrdinalIgnoreCase);
            if (updated == current) return;
            SetEditorText(updated);
        };
        SecondaryButtonClick += (_, args) => { args.Cancel = true; if (saving) return; SetEditorText(document.Text); problem.IsOpen = false; Highlight(); Update(); };
        async Task SaveAsync()
        {
            if (saving || !HasChanges()) return;
            saving = true; editor.IsReadOnly = true; Update();
            try
            {
                var newline = document.Text.Contains("\r\n") ? "\r\n" : document.Text.Contains('\n') ? "\n" : document.Text.Contains('\r') ? "\r" : Environment.NewLine;
                await document.SaveAsync(EditorText().ReplaceLineEndings(newline));
                problem.IsOpen = false; Update();
            }
            catch (Exception ex) { problem.Message = ex.Message; problem.ActionButton = null; problem.IsOpen = true; }
            finally { saving = false; editor.IsReadOnly = false; Update(); }
        }
        PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try { await SaveAsync(); } finally { deferral.Complete(); }
        };
        Closing += (_, args) =>
        {
            if (saving) { args.Cancel = true; return; }
            if (!allowDiscard && HasChanges())
            {
                args.Cancel = true;
                problem.Message = "This file has unsaved changes."; problem.ActionButton = discard; problem.IsOpen = true;
            }
        };
        discard.Click += (_, _) => { if (saving) return; allowDiscard = true; Hide(); };
        void Shortcut(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, args) => { args.Handled = true; action(); };
            KeyboardAccelerators.Add(accelerator);
        }
        Shortcut(VirtualKey.F, VirtualKeyModifiers.Control, () => { search.Focus(FocusState.Programmatic); search.SelectAll(); });
        Shortcut(VirtualKey.H, VirtualKeyModifiers.Control, () => { replaceToggle.IsChecked = true; search.Focus(FocusState.Programmatic); search.SelectAll(); });
        Shortcut(VirtualKey.S, VirtualKeyModifiers.Control, async () => await SaveAsync());
        Shortcut(VirtualKey.F3, VirtualKeyModifiers.None, () => Find());
        Shortcut(VirtualKey.F3, VirtualKeyModifiers.Shift, () => Find(true));
        Loaded += (_, _) =>
        {
            body.Width = Math.Max(300, Math.Min(760, XamlRoot.Size.Width - 110));
            body.Height = Math.Max(260, Math.Min(470, XamlRoot.Size.Height - 230));
            UpdateLineNumbers(); Highlight();
            if (FindDescendant<ScrollViewer>(editor) is { } editorScroller)
                editorScroller.ViewChanged += (_, _) => lineScroller.ChangeView(null, editorScroller.VerticalOffset, null, true);
            Update();
        };
        Update();
    }

    private static T? FindDescendant<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is T found) return found;
            if (FindDescendant<T>(child) is { } nested) return nested;
        }
        return null;
    }
}
