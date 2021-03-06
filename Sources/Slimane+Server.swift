//
//  Serve.swift
//  Slimane
//
//  Created by Yuki Takei on 4/16/16.
//
//

extension Slimane {
    public func listen(loop: Loop = Loop.defaultLoop, host: String = "0.0.0.0", port: Int = 3000, errorHandler: (ErrorProtocol) -> () = { _ in }) throws {
        let server = HTTPServer(loop: loop, ipcEnable: Cluster.isWorker) { [unowned self] in
            do {
                let (request, stream) = try $0()
                self.dispatch(request, stream: stream)
            } catch {
                errorHandler(error)
            }
        }

        server.setNoDelay = self.setNodelay
        server.keepAliveTimeout = self.keepAliveTimeout
        server.backlog = self.backlog
        
        if self.middlewares.count == 0 {
            // Register dummy middleware to suppress error
            self.use { req, res, next in
                next(.Chain(req, res))
            }
        }

        if Cluster.isMaster {
            try server.bind(Address(host: host, port: port))
        }
        try server.listen()
    }

    private func dispatch(_ request: Request, stream: Skelton.HTTPStream){
        let responder = BasicAsyncResponder { [unowned self] request, result in
            if request.isIntercepted {
                result {
                    request.response
                }
                return
            }

            var request = request
            if let route = self.router.match(request) {
                request.params = route.params(request)
                route.handler.respond(to: request) { response in
                    result {
                        request.response.merged(try response())
                    }
                }
            } else {
                result {
                    self.errorHandler(Error.RouteNotFound(path: request.uri.path ?? "/"))
                }
            }
        }

        self.middlewares.chain(to: responder).respond(to: request) { [unowned self] in
            do {
                let response = try $0()
                if let responder = response.customResponder {
                    responder.respond(response) {
                        do {
                            self.processStream(try $0(), request, stream)
                        } catch {
                            self.handleError(error, request, stream)
                        }
                    }
                } else if case .asyncSender(let closure) =  response.body {
                    closure(stream) {
                        do {
                            try $0()
                        } catch {
                            do { try stream.close() } catch {}
                        }
                    }
                } else {
                    self.processStream(response, request, stream)
                }
            } catch {
                self.handleError(error, request, stream)
            }
        }
    }

    private func processStream(_ response: Response, _ request: Request, _ stream: Skelton.HTTPStream){
        var response = response

        response.headers["Date"] = Header(Time().rfc1123)
        response.headers["Server"] = Header("Slimane")

        if response.headers["Connection"].isEmpty {
            response.headers["Connection"] = Header(request.isKeepAlive ? "Keep-Alive" : "Close")
        }

        if response.contentLength == 0 && !response.isChunkEncoded {
            response.contentLength = response.bodyLength
        }
        
        stream.send(response.serialize)
        closeStream(request, stream)
    }

    private func handleError(_ error: ErrorProtocol, _ request: Request, _ stream: Skelton.HTTPStream){
        let response = errorHandler(error)
        processStream(response, request, stream)
    }
}

private func closeStream(_ request: Request, _ stream: Skelton.HTTPStream){
    if !request.isKeepAlive {
        do {
            try stream.close()
        } catch { }
    }
}
