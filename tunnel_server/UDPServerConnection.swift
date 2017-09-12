/*
	Copyright (C) 2016 Apple Inc. All Rights Reserved.
	See LICENSE.txt for this sample’s licensing information
	
	Abstract:
	This file contains the UDPServerConnection class. The UDPServerConnection class handles the encapsulation and decapsulation of datagrams in the server side of the SimpleTunnel tunneling protocol.
*/

import Foundation
import Darwin

/// An object representing the server side of a logical flow of UDP network data in the SimpleTunnel tunneling protocol.
class UDPServerConnection: Connection {

	// MARK: Properties

	/// The address family of the UDP socket.
    var addressFamily: Int32 = AF_UNSPEC

	/// A dispatch source for reading data from the UDP socket.
    var responseSource: DispatchSourceProtocol?

	// MARK: Initializers
    
    override init(connectionIdentifier: Int, parentTunnel: Tunnel) {
		super.init(connectionIdentifier: connectionIdentifier, parentTunnel: parentTunnel)
    }
    
    deinit {
		if let source = responseSource {
            source.cancel()
		}
    }

	// MARK: Interface

	/// Convert a sockaddr structure into an IP address string and port.
    func getEndpointFromSocketAddress(socketAddressPointer: UnsafePointer<sockaddr>) -> (host: String, port: Int)? {
		let socketAddress = UnsafePointer<sockaddr>(socketAddressPointer).pointee

		switch Int32(socketAddress.sa_family) {
			case AF_INET:
                
                return socketAddressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: MemoryLayout<sockaddr>.size) { (socketAddressInetPointer: UnsafePointer<sockaddr_in>) -> (host: String, port: Int) in
                    let length = Int(INET_ADDRSTRLEN) + 2
                    var buffer = [CChar](repeating: 0, count: length)
                    var sin_addr = socketAddressInetPointer.pointee.sin_addr
                    let hostCString = inet_ntop(AF_INET, &sin_addr, &buffer, socklen_t(length))
                    let port = Int(UInt16(socketAddressInetPointer.pointee.sin_port).byteSwapped)
                    return (String(cString: hostCString!), port)
                }
			case AF_INET6:
                
                return socketAddressPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: MemoryLayout<sockaddr>.size) { (socketAddressInet6Pointer : UnsafePointer<sockaddr_in6>) -> (host: String, port: Int) in
                    let length = Int(INET6_ADDRSTRLEN) + 2
                    var buffer = [CChar](repeating: 0, count: length)
                    var sin6_addr = socketAddressInet6Pointer.pointee.sin6_addr
                    let hostCString = inet_ntop(AF_INET6, &sin6_addr, &buffer, socklen_t(length))
                    let port = Int(UInt16(socketAddressInet6Pointer.pointee.sin6_port).byteSwapped)
                    return (String(cString: hostCString!), port)
                }
            
			default:
				return nil
		}
    }

    /// Create a UDP socket
    func createSocketWithAddressFamilyFromAddress(address: String) -> Bool {
		var sin = sockaddr_in()
		var sin6 = sockaddr_in6()
		var newSocket: Int32 = -1

		if address.withCString({ cstring in inet_pton(AF_INET6, cstring, &sin6.sin6_addr) }) == 1 {
			// IPv6 peer.
			newSocket = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
			addressFamily = AF_INET6
		}
		else if address.withCString({ cstring in inet_pton(AF_INET, cstring, &sin.sin_addr) }) == 1 {
			// IPv4 peer.
			newSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
			addressFamily = AF_INET
		}

		guard newSocket > 0 else { return false }

        let newResponseSource = DispatchSource.makeReadSource(fileDescriptor: newSocket, queue: DispatchQueue.main)
        
        newResponseSource.setCancelHandler {
            simpleTunnelLog("closing udp socket for connection \(self.identifier)")
			let UDPSocket = Int32(newResponseSource.handle)
			close(UDPSocket)
		}
        
        newResponseSource.setEventHandler {
            guard let source = self.responseSource else { return }
            
			var socketAddress = sockaddr_storage()
			var socketAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
			let response = [UInt8](repeating: 0, count: 4096)
			let UDPSocket = Int32(source.handle)
            
            let bytesRead = withUnsafeMutablePointer(to: &socketAddress, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: MemoryLayout<sockaddr_storage>.size, {
                    recvfrom(UDPSocket, UnsafeMutableRawPointer(mutating: response), response.count, 0, $0, &socketAddressLength)
                })
            })
            
            guard bytesRead >= 0 else {
                if let errorString = String(utf8String: strerror(errno)) {
                    simpleTunnelLog("recvfrom failed: \(errorString)")
                }
                self.closeConnection(.all)
                return
            }
            
            guard bytesRead > 0 else {
                simpleTunnelLog("recvfrom returned EOF")
                self.closeConnection(.all)
                return
            }
            
            guard let endpoint = withUnsafePointer(to: &socketAddress, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: MemoryLayout<sockaddr_storage>.size, {
                    return self.getEndpointFromSocketAddress(socketAddressPointer: $0)
                })
            })
            else {
                simpleTunnelLog("Failed to get the address and port from the socket address received from recvfrom")
                self.closeConnection(.all)
                return
            }
            
            let responseDatagram = Data(bytes: UnsafeRawPointer(response), count: bytesRead)
            simpleTunnelLog("UDP connection id \(self.identifier) received = \(bytesRead) bytes from host = \(endpoint.host) port = \(endpoint.port)")
            self.tunnel?.sendDataWithEndPoint(responseDatagram, forConnection: self.identifier, host: endpoint.host, port: endpoint.port)
        }

		newResponseSource.resume()
		responseSource = newResponseSource

		return true
    }

    /// Send a datagram to a given host and port.
    override func sendDataWithEndPoint(_ data: Data, host: String, port: Int) {

		if responseSource == nil {
			guard createSocketWithAddressFamilyFromAddress(address: host) else {
				simpleTunnelLog("UDP ServerConnection initialization failed.")
				return
			}
		}

		guard let source = responseSource else { return }
		let UDPSocket = Int32(source.handle)
		let sent: Int

		switch addressFamily {
			case AF_INET:
				let serverAddress = SocketAddress()
				guard serverAddress.setFromString(host) else {
					simpleTunnelLog("Failed to convert \(host) into an IPv4 address")
					return
				}
				serverAddress.setPort(port)

				sent = withUnsafePointer(to: &serverAddress.sin, {
					$0.withMemoryRebound(to: sockaddr.self, capacity: MemoryLayout<sockaddr_in>.size, { (sockaddrPointer) in
                        data.withUnsafeBytes({ (bytes) in
                            sendto(UDPSocket, bytes, data.count, 0, sockaddrPointer, socklen_t(serverAddress.sin.sin_len))
                        })
                    })
                })
                
			case AF_INET6:
				let serverAddress = SocketAddress6()
				guard serverAddress.setFromString(host) else {
					simpleTunnelLog("Failed to convert \(host) into an IPv6 address")
					return
				}
				serverAddress.setPort(port)

                sent = withUnsafePointer(to: &serverAddress.sin6, {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: MemoryLayout<sockaddr_in>.size, { (sockaddrPointer) in
                        data.withUnsafeBytes({ (bytes) in
                            sendto(UDPSocket, bytes, data.count, 0, sockaddrPointer, socklen_t(serverAddress.sin6.sin6_len))
                        })
                    })
                })

			default:
				return
        }

		guard sent > 0 else {
			if let errorString = String(utf8String: strerror(errno)) {
				simpleTunnelLog("UDP connection id \(identifier) failed to send data to host = \(host) port \(port). error = \(errorString)")
			}
			closeConnection(.all)
			return
		}

		if sent == data.count {
			// Success
			simpleTunnelLog("UDP connection id \(identifier) sent \(data.count) bytes to host = \(host) port \(port)")
		}
    }

	/// Close the connection.
	override func closeConnection(_ direction: TunnelConnectionCloseDirection) {
		super.closeConnection(direction)

		if let source = responseSource, isClosedForWrite && isClosedForRead {
            source.cancel()
			responseSource = nil
		}
	}
}





