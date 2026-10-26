using System.Net;
using System.Net.Sockets;

namespace ServerMaster.Windows.Services;

public sealed record PortReservation(int Port, string Note, DateTimeOffset CreatedAt)
{
    public string Display => string.IsNullOrWhiteSpace(Note) ? Port.ToString() : $"{Port}  {Note}";
}

public sealed class PortReserver : IDisposable
{
    private readonly Dictionary<int, (TcpListener Listener, PortReservation Reservation)> _held = [];

    public IReadOnlyList<PortReservation> Reservations
    {
        get { lock (_held) return _held.Values.Select(item => item.Reservation).OrderBy(item => item.Port).ToArray(); }
    }

    public bool IsReserved(int port)
    {
        lock (_held) return _held.ContainsKey(port);
    }

    public PortReservation Reserve(int port, string note)
    {
        if (port is < 1 or > 65535) throw new InvalidOperationException("Enter a port from 1 to 65535.");
        if (note.Length > 120 || note.Any(char.IsControl)) throw new InvalidOperationException("The reservation note must be at most 120 printable characters.");
        lock (_held)
        {
            if (_held.ContainsKey(port)) throw new InvalidOperationException($"Port {port} is already reserved inside ServerMaster.");
            var listener = new TcpListener(IPAddress.Any, port);
            listener.ExclusiveAddressUse = true;
            try { listener.Start(1); }
            catch (SocketException ex)
            {
                listener.Stop();
                throw new InvalidOperationException($"Could not reserve port {port}: {ex.Message}", ex);
            }
            var reservation = new PortReservation(port, note.Trim(), DateTimeOffset.Now);
            _held.Add(port, (listener, reservation));
            return reservation;
        }
    }

    public void Release(int port)
    {
        lock (_held)
        {
            if (!_held.Remove(port, out var item)) return;
            item.Listener.Stop();
        }
    }

    public void ReleaseAll()
    {
        lock (_held)
        {
            foreach (var item in _held.Values) item.Listener.Stop();
            _held.Clear();
        }
    }

    public void Dispose() => ReleaseAll();
}
