#ifndef TARANTOOL_SIO_H_INCLUDED
#define TARANTOOL_SIO_H_INCLUDED
/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
/**
 * Exception-aware wrappers around BSD sockets.
 * Provide better error logging and I/O statistics.
 */
#include <stdbool.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include "exception.h"

enum { SERVICE_NAME_MAXLEN = 32 };

@interface SocketError: SystemError
- (id) init: (int) fd in: (const char *) format, ...;
@end

int sio_socket(void);

int sio_getfl(int fd);
int sio_setfl(int fd, int flag, int on);

void
sio_setsockopt(int fd, int level, int optname,
	       const void *optval, socklen_t optlen);
void
sio_getsockopt(int fd, int level, int optname,
	       void *optval, socklen_t *optlen);

int sio_connect(int fd, struct sockaddr_in *addr, socklen_t addrlen);
int sio_bind(int fd, struct sockaddr_in *addr, socklen_t addrlen);
int sio_listen(int fd);
int sio_accept(int fd, struct sockaddr_in *addr, socklen_t *addrlen);

ssize_t sio_read(int fd, void *buf, size_t count);
ssize_t sio_write(int fd, const void *buf, size_t count);
ssize_t sio_writev(int fd, const struct iovec *iov, int iovcnt);

int sio_getpeername(int fd, struct sockaddr_in *addr);
const char *sio_strfaddr(struct sockaddr_in *addr);

/**
 * Advance write position in the iovec array
 * based on its current value and the number of
 * bytes written.
 *
 * @param[in]  iov        the vector being written with writev().
 * @param[in]  nwr        number of bytes written, @pre >= 0
 * @param[in,out] iov_len offset in iov[0];
 *
 * @return                offset of iov[0] for the next write
 */
static inline int
sio_move_iov(struct iovec *iov, ssize_t nwr, size_t *iov_len)
{
	nwr += *iov_len;
	struct iovec *begin = iov;
	while (nwr > 0 && nwr >= iov->iov_len) {
		nwr -= iov->iov_len;
		iov++;
	}
	*iov_len = nwr;
	return iov - begin;
}

/**
 * Change values of iov->iov_len and iov->iov_base
 * to adjust to a partial write.
 */
static inline void
sio_add_to_iov(struct iovec *iov, ssize_t size)
{
	iov->iov_len += size;
	iov->iov_base -= size;
}

#endif /* TARANTOOL_SIO_H_INCLUDED */
